import Foundation

/// The container's side of sync: the delegate of its provider's engine, for every zone that syncs.
///
/// The engine decides when to sync. The hub tells it what is pending, builds the batches it asks for from
/// each zone's change log, and applies what it reports: received records, acknowledgements, conflicts,
/// account changes and zone resets. Contexts reach it through each zone's `ZoneSync`.
actor SyncHub: SyncDelegate {
    /// Changes in one request, so a server is never asked to take too many at once.
    static let batchSize = 200
    /// How many of a zone's pending changes the engine hears of at a time.
    static let pendingWindow = 1_000
    /// Rounds of conflicts one record may meet in one send, so two copies that never settle can't loop.
    private static let maxConflictRounds = 20

    nonisolated let provider: any SyncProvider
    /// The zones that sync and are open. Kept weakly: each zone's storage owns its `ZoneSync`.
    nonisolated let registry = Registry()
    /// Where the engine's state is kept, or `nil` to keep it in memory.
    private let stateDirectory: URL?
    /// Opens a zone that a server's changes arrive for, or `nil` when the zone doesn't sync.
    private let openZone: @Sendable (Zone) -> ZoneSync?

    private var startTask: Task<Void, Never>?
    private var memoryState: [Zone.Scope: Data] = [:]
    /// The signed-in account as the engine last reported it, `.some(nil)` for signed out, `nil` before it said.
    private var account: String??

    /// The changes in the requests of the send running now, by record ID.
    private var inFlight: [UUID: (sync: ZoneSync, change: PendingChange, fields: SyncFields?)] = [:]
    /// Records already given to the send running now, which aren't given again unless they met a conflict.
    private var attempted: Set<UUID> = []
    private var conflictRounds: [UUID: Int] = [:]

    init(provider: any SyncProvider, directory: URL?, openZone: @escaping @Sendable (Zone) -> ZoneSync?) {
        self.provider = provider
        stateDirectory = directory?.appendingPathComponent("_sync", isDirectory: true)
        self.openZone = openZone
    }

    // MARK: Starting

    /// Hands the engine its saved state, once.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task {
            account = loadAccount()
            for scope in provider.scopes.sorted(by: { $0.rawValue < $1.rawValue }) {
                await provider.start(scope, state: loadState(scope), delegate: self)
            }
        }
        startTask = task
        await task.value
    }

    /// The signed-in account, if the engine has reported one.
    var signedInUser: String? { account ?? nil }

    var isSignedOut: Bool { account == .some(nil) }

    // MARK: Calls from zones

    /// Readies a zone that just opened: brings it in line with the server and account, tells the engine
    /// what it has pending, then sends.
    func open(_ sync: ZoneSync) async {
        await start()
        sync.prepare(identifier: provider.identifier)
        if let user = signedInUser {
            sync.applyAccount(user)
        } else if isSignedOut {
            sync.setSignedOut(true)
        }
        provider.addPending([PendingZoneChange.save(sync.zone)])
        registerPending(sync)
        await perform([sync]) {
            try await self.provider.sendChanges(SendOptions(scope: .zones([sync.zone])))
        }
    }

    /// Sends what the zone has pending.
    func send(_ sync: ZoneSync) async {
        await start()
        await perform([sync]) {
            try await self.provider.sendChanges(SendOptions(scope: .zones([sync.zone])))
        }
    }

    /// Sends, fetches the server's changes, then sends what merging left.
    func refresh(_ sync: ZoneSync) async {
        await start()
        let zone = sync.zone
        await perform([sync]) {
            try await self.provider.sendChanges(SendOptions(scope: .zones([zone])))
            try await self.provider.fetchChanges(FetchOptions(scope: .zones([zone]), prioritizedZones: [zone]))
            if !((try? sync.store.pendingChanges(limit: 1)) ?? []).isEmpty {
                try await self.provider.sendChanges(SendOptions(scope: .zones([zone])))
            }
        }
    }

    /// Fetches the server's changes without sending.
    func download(_ sync: ZoneSync) async {
        await start()
        let zone = sync.zone
        await perform([sync]) {
            try await self.provider.fetchChanges(FetchOptions(scope: .zones([zone]), prioritizedZones: [zone]))
        }
    }

    /// Tells the engine about the zone's pending changes, a window at a time.
    func registerPending(_ sync: ZoneSync) {
        guard let pending = try? sync.store.pendingChanges(limit: Self.pendingWindow), !pending.isEmpty else { return }
        provider.addPending(pending.map {
            $0.kind == .delete ? PendingRecordChange.delete($0.id, sync.zone) : PendingRecordChange.save($0.id, sync.zone)
        })
    }

    private func perform(_ zones: [ZoneSync], _ body: @escaping @Sendable () async throws -> Void) async {
        for sync in zones {
            sync.begin()
        }
        var thrown: (any Error)?
        do {
            try await body()
        } catch {
            thrown = error
        }
        for sync in zones {
            sync.finish(error: thrown, signedOut: isSignedOut)
        }
    }

    // MARK: SyncDelegate

    func handle(_ event: SyncEvent) async {
        switch event {
        case .stateUpdate(let scope, let data):
            saveState(data, scope: scope)
        case .accountChange(let change):
            accountChanged(change)
        case .fetchedZoneChanges(_, let deleted):
            for deletion in deleted {
                zoneDeleted(deletion)
            }
        case .fetchedRecordChanges(let saved, let deleted):
            received(saved + deleted.map { RecordChangeData(id: $0.id, zone: $0.zone, type: $0.type, fields: nil) })
        case .sentZoneChanges(let result):
            // A zone that failed to save is tried again with the next send.
            provider.addPending(result.failed.filter { $0.failure != .permissionFailure }.map { PendingZoneChange.save($0.zone) })
        case .sentRecordChanges(let result):
            sent(result)
        case .willFetchChanges(let context):
            for sync in registry.all where context.options.scope.contains(sync.zone) {
                sync.markSyncing()
            }
        case .willFetchZoneChanges(let zone):
            registry[zone]?.markSyncing()
        case .didFetchZoneChanges:
            break
        case .didFetchChanges(let context):
            for sync in registry.all where context.options.scope.contains(sync.zone) {
                await refetch(sync)
            }
            if context.reason == .scheduled {
                for sync in registry.all where context.options.scope.contains(sync.zone) {
                    sync.finish(error: nil, signedOut: isSignedOut)
                }
            }
        case .willSendChanges(let context):
            inFlight = [:]
            attempted = []
            conflictRounds = [:]
            if context.reason == .scheduled {
                for sync in registry.all where context.options.scope.contains(sync.zone) {
                    sync.begin()
                }
            }
        case .didSendChanges(let context):
            inFlight = [:]
            attempted = []
            conflictRounds = [:]
            for sync in registry.all where context.options.scope.contains(sync.zone) {
                registerPending(sync)
                if context.reason == .scheduled {
                    sync.finish(error: nil, signedOut: isSignedOut)
                }
            }
        }
    }

    func nextBatch(_ context: SendContext) async -> RecordBatch? {
        guard !isSignedOut else { return nil }
        var batch = RecordBatch()
        var count = 0
        var records: Set<UUID>?
        if case .records(let ids) = context.options.scope {
            records = ids
        }
        for sync in registry.all.sorted(by: { $0.zone.name < $1.zone.name }) where context.options.scope.contains(sync.zone) {
            guard count < Self.batchSize else { break }
            let store = sync.store
            guard let pending = try? store.pendingChanges(limit: Self.batchSize + attempted.count) else { continue }
            for change in pending {
                guard count < Self.batchSize else { break }
                guard !attempted.contains(change.id), records?.contains(change.id) ?? true else { continue }
                attempted.insert(change.id)
                guard let (record, fields, base) = try? store.syncRecord(for: change),
                      let data = try? store.change(for: record, zone: sync.zone, base: base) else { continue }
                inFlight[change.id] = (sync, change, fields)
                if data.isDeletion {
                    batch.deletes.append(RecordDeletion(id: data.id, zone: data.zone, type: data.type, tag: data.tag))
                } else {
                    batch.saves.append(data)
                }
                count += 1
                sync.markSyncing()
            }
        }
        return batch.isEmpty ? nil : batch
    }

    func nextFetchOptions(_ context: FetchContext) async -> FetchOptions {
        var options = context.options
        // The zones contexts are showing come first.
        options.prioritizedZones = registry.all.filter(\.isShown).map(\.zone) + options.prioritizedZones
        return options
    }

    // MARK: Events

    private func accountChanged(_ change: AccountChange) {
        switch change {
        case .signIn(let user), .switchAccounts(_, let user):
            account = .some(user)
            saveAccount(user)
            for sync in registry.all {
                sync.setSignedOut(false)
                sync.applyAccount(user)
                registerPending(sync)
            }
        case .signOut:
            // Records stay, tied to the account that synced them: edits wait for it to sign back in, and a
            // different account replaces them.
            account = .some(nil)
            saveAccount(nil)
            for sync in registry.all {
                sync.setSignedOut(true)
            }
        }
    }

    private func zoneDeleted(_ deletion: ZoneDeletion) {
        guard let sync = registry[deletion.zone] else { return }
        switch deletion.reason {
        case .deleted, .purged:
            // The person removed this data from the server, so it goes from this device too.
            sync.deleteLocalData()
        case .encryptedDataReset:
            // The server lost the data but the person didn't mean to, so this device's copy goes up again.
            sync.keepLocalData()
            provider.addPending([PendingZoneChange.save(deletion.zone)])
            registerPending(sync)
        }
    }

    private func received(_ changes: [RecordChangeData]) {
        for (zone, group) in Dictionary(grouping: changes, by: \.zone) {
            guard let sync = registry[zone] ?? openZone(zone) else { continue }
            sync.receive(group)
            registerPending(sync)
        }
    }

    /// Fetches whole the records whose partial changes this device couldn't apply. A failure keeps them
    /// for the next fetch, and the zone shows offline.
    private func refetch(_ sync: ZoneSync) async {
        guard let ids = try? sync.refetch(), !ids.isEmpty else { return }
        do {
            let changes = try await provider.fetchRecords(ids)
            sync.refetched(ids, changes: changes)
            registerPending(sync)
        } catch {
            sync.markOffline()
        }
    }

    private func sent(_ result: SentRecordChanges) {
        var conflicts: [ObjectIdentifier: (sync: ZoneSync, changes: [RecordChangeData])] = [:]
        func conflict(_ sync: ZoneSync, _ change: RecordChangeData) {
            conflicts[ObjectIdentifier(sync), default: (sync, [])].changes.append(change)
            // A merged record goes again in this send, unless it keeps conflicting.
            let rounds = conflictRounds[change.id, default: 0] + 1
            conflictRounds[change.id] = rounds
            if rounds < Self.maxConflictRounds {
                attempted.remove(change.id)
            }
        }
        func failed(_ id: UUID, _ failure: SyncFailure) {
            guard let entry = inFlight.removeValue(forKey: id) else { return }
            switch failure {
            case .serverRecordChanged(let server):
                conflict(entry.sync, server)
            case .unknownItem:
                if entry.change.kind == .delete {
                    entry.sync.acknowledge(entry.change, fields: nil, tag: nil, synced: nil)
                } else {
                    // A server delete beats a local edit.
                    conflict(entry.sync, RecordChangeData(id: id, zone: entry.sync.zone, type: entry.change.table, fields: nil))
                }
            case .zoneNotFound:
                provider.addPending([PendingZoneChange.save(entry.sync.zone)])
                attempted.remove(id)
            case .quotaExceeded:
                entry.sync.fail(.storageFull)
            case .networkUnavailable, .other:
                entry.sync.markOffline()
            case .limitExceeded, .permissionFailure:
                entry.sync.fail(.rejected(type: entry.change.table, id: id))
            }
        }

        for saved in result.saved {
            guard let entry = inFlight.removeValue(forKey: saved.id) else { continue }
            entry.sync.acknowledge(entry.change, fields: entry.fields, tag: saved.tag, synced: saved.synced)
        }
        for deleted in result.deleted {
            guard let entry = inFlight.removeValue(forKey: deleted.id) else { continue }
            entry.sync.acknowledge(entry.change, fields: nil, tag: nil, synced: nil)
        }
        for failure in result.failed {
            failed(failure.change.id, failure.failure)
        }
        for failure in result.failedDeletes {
            failed(failure.deletion.id, failure.failure)
        }
        // A conflict's merge stays pending and goes in the next batch, based on the server's copy.
        for (_, entry) in conflicts {
            entry.sync.receive(entry.changes)
        }
    }

    // MARK: Stored state

    private nonisolated var stateKey: String {
        // A short stable name for the provider, so each server keeps its own state.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in provider.identifier.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private func stateFile(_ name: String) -> URL? {
        stateDirectory?.appendingPathComponent("\(stateKey).\(name)")
    }

    private func loadState(_ scope: Zone.Scope) -> Data? {
        guard let file = stateFile("\(scope.rawValue).state") else { return memoryState[scope] }
        return try? Data(contentsOf: file)
    }

    private func saveState(_ data: Data, scope: Zone.Scope) {
        guard let file = stateFile("\(scope.rawValue).state") else {
            memoryState[scope] = data
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func loadAccount() -> String?? {
        guard let file = stateFile("account"), let data = try? Data(contentsOf: file) else { return nil }
        return .some(String(data: data, encoding: .utf8))
    }

    private func saveAccount(_ user: String?) {
        guard let file = stateFile("account") else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let user {
            try? Data(user.utf8).write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension SyncHub {
    /// The open zones that sync, held weakly.
    final class Registry: @unchecked Sendable {
        private struct Entry {
            weak var sync: ZoneSync?
        }

        private let lock = NSLock()
        private var entries: [Zone: Entry] = [:]

        func add(_ sync: ZoneSync) {
            lock.withLock { entries[sync.zone] = Entry(sync: sync) }
        }

        subscript(zone: Zone) -> ZoneSync? {
            lock.withLock { entries[zone]?.sync }
        }

        var all: [ZoneSync] {
            lock.withLock { entries.values.compactMap(\.sync) }
        }
    }
}
