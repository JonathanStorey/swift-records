import Foundation

/// What a server without a sync engine of its own provides: the requests `CKSyncEngine` makes of CloudKit,
/// one method each. `PollingSyncEngine` drives a transport and does the rest.
///
/// Throw `SyncFailure` when a whole request fails, such as `.networkUnavailable`. Answer for each record in
/// the results instead when only some of a batch fails.
public protocol SyncTransport: Sendable {
    /// Names the server, such as its URL.
    var identifier: String { get }

    /// The databases the server has. The default is `.private` alone.
    var scopes: Set<Zone.Scope> { get }

    /// A stable ID for the signed-in user, or `nil` when signed out. ≈ `fetchUserRecordID()`.
    func currentUser() async throws -> String?

    /// Creates and deletes zones. ≈ `CKModifyRecordZonesOperation`. The default reports every change done,
    /// for a server whose zones need no creating.
    func modifyZones(save: [Zone], delete: [Zone]) async throws -> SentZoneChanges

    /// Saves and deletes a batch. ≈ `CKModifyRecordsOperation`. A server that versions records accepts a save
    /// only when its `tag` matches the server's copy, or it is `nil` and the server has no copy, and
    /// otherwise fails it with `.serverRecordChanged` and the server's copy.
    func modifyRecords(_ batch: RecordBatch) async throws -> SentRecordChanges

    /// The zones that changed or were deleted since `token`. ≈ `CKFetchDatabaseChangesOperation`.
    func fetchDatabaseChanges(_ scope: Zone.Scope, since token: Data?) async throws -> DatabaseChanges

    /// A zone's changes since `token`, oldest first, with each record's latest change only.
    /// ≈ `CKFetchRecordZoneChangesOperation`.
    func fetchZoneChanges(_ zone: Zone, since token: Data?) async throws -> ZoneChanges

    /// The server's whole copy of each record, and a deletion for one it no longer has.
    /// ≈ `CKFetchRecordsOperation`. A transport whose zone changes are ever partial must implement it: the
    /// container asks when it lacks the copy a partial change builds on. The default throws.
    func fetchRecords(_ records: [RecordID]) async throws -> [RecordChangeData]

    /// Zones the server says have changed, such as from a push. Each call returns a new stream. `nil`, the
    /// default, means the transport can't tell.
    func changeNotifications() -> AsyncStream<[Zone]>?
}

extension SyncTransport {
    public var scopes: Set<Zone.Scope> { [.private] }

    public func modifyZones(save: [Zone], delete: [Zone]) async throws -> SentZoneChanges {
        SentZoneChanges(saved: save, deleted: delete)
    }

    public func changeNotifications() -> AsyncStream<[Zone]>? { nil }

    public func fetchRecords(_ records: [RecordID]) async throws -> [RecordChangeData] {
        throw SyncFailure.other("\(Self.self) sends only whole records, so it can't fetch them one by one")
    }
}

/// The zones a database fetch found. ≈ `CKSyncEngine.Event.FetchedDatabaseChanges`.
public struct DatabaseChanges: Sendable, Hashable {
    /// Zones with changes to fetch.
    public var modified: [Zone]
    public var deleted: [ZoneDeletion]
    /// Where the next database fetch starts.
    public var token: Data?

    public init(modified: [Zone], deleted: [ZoneDeletion] = [], token: Data?) {
        self.modified = modified
        self.deleted = deleted
        self.token = token
    }
}

/// A page of a zone's changes. ≈ `CKSyncEngine.Event.FetchedRecordZoneChanges` with its change token.
public struct ZoneChanges: Sendable, Hashable {
    public var saved: [RecordChangeData]
    public var deleted: [RecordDeletion]
    /// Where the next fetch of this zone starts.
    public var token: Data?
    /// Whether more changes wait after this page.
    public var moreComing: Bool

    public init(saved: [RecordChangeData], deleted: [RecordDeletion] = [], token: Data?, moreComing: Bool = false) {
        self.saved = saved
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

/// A sync engine for any `SyncTransport`, behaving as `CKSyncEngine` does: it keeps the account, change
/// tokens and pending changes in a state it hands the container to store, runs one operation at a time,
/// and reports what happens as `SyncEvent`s.
///
/// ```swift
/// let engine = PollingSyncEngine(transport: FileSyncTransport())
/// let container = try RecordContainer(for: [Recipe.self], syncProvider: engine)
/// ```
///
/// With `automaticallySync`, the default, it fetches as it starts and when the transport reports changes,
/// and sends a moment after changes are added. Without it, it syncs only when asked, for tests.
public final class PollingSyncEngine: SyncProvider, @unchecked Sendable {
    public let transport: any SyncTransport
    public let automaticallySync: Bool
    /// How long changes wait before an automatic send, so a burst of saves goes together.
    public let sendDelay: Duration

    private struct State: Codable {
        /// Whether the engine has checked the account at least once.
        var knowsUser = false
        var user: String?
        var databaseTokens: [Zone.Scope: Data] = [:]
        var zoneTokens: [Zone: Data] = [:]
        /// Zones a database fetch found changed that a fetch of other zones left for later.
        var unfetchedZones: Set<Zone> = []
        var pendingRecords: Set<PendingRecordChange> = []
        var pendingZones: Set<PendingZoneChange> = []
    }

    private let lock = NSLock()
    private var state = State()
    private weak var delegate: (any SyncDelegate)?
    private var started = false
    private let gate = OperationGate()
    private var scheduledSend: Task<Void, Never>?
    private var listener: Task<Void, Never>?

    public init(transport: any SyncTransport, automaticallySync: Bool = true, sendDelay: Duration = .seconds(1)) {
        self.transport = transport
        self.automaticallySync = automaticallySync
        self.sendDelay = sendDelay
    }

    deinit {
        scheduledSend?.cancel()
        listener?.cancel()
    }

    public var identifier: String { transport.identifier }

    public var scopes: Set<Zone.Scope> { transport.scopes }

    public var assetTransfer: (any AssetTransfer)? { transport as? any AssetTransfer }

    /// The transport, when it conforms to `ZoneSharing`.
    public var sharing: (any ZoneSharing)? { transport as? any ZoneSharing }

    public func start(_ scope: Zone.Scope, state data: Data?, delegate: any SyncDelegate) async {
        let first = lock.withLock {
            if let data, let decoded = try? JSONDecoder().decode(State.self, from: data) {
                state = decoded
            }
            self.delegate = delegate
            defer { started = true }
            return !started
        }
        guard first, automaticallySync else { return }
        if let changes = transport.changeNotifications() {
            let task = Task { [weak self] in
                for await zones in changes {
                    guard let self else { return }
                    try? await self.fetch(FetchOptions(scope: .zones(Set(zones))), reason: .scheduled)
                    try? await self.send(SendOptions(scope: .zones(Set(zones))), reason: .scheduled)
                }
            }
            lock.withLock { listener = task }
        }
        Task { [weak self] in
            try? await self?.fetch(FetchOptions(), reason: .scheduled)
            try? await self?.send(SendOptions(), reason: .scheduled)
        }
    }

    // MARK: Pending changes

    public func addPending(_ changes: [PendingRecordChange]) {
        guard !changes.isEmpty else { return }
        lock.withLock { state.pendingRecords.formUnion(changes) }
        scheduleSend()
    }

    public func removePending(_ changes: [PendingRecordChange]) {
        lock.withLock { state.pendingRecords.subtract(changes) }
    }

    public func addPending(_ changes: [PendingZoneChange]) {
        guard !changes.isEmpty else { return }
        lock.withLock { state.pendingZones.formUnion(changes) }
        scheduleSend()
    }

    public func removePending(_ changes: [PendingZoneChange]) {
        lock.withLock { state.pendingZones.subtract(changes) }
    }

    private func scheduleSend() {
        guard automaticallySync else { return }
        lock.withLock {
            guard scheduledSend == nil else { return }
            scheduledSend = Task { [weak self, sendDelay] in
                try? await Task.sleep(for: sendDelay)
                guard let self else { return }
                self.lock.withLock { self.scheduledSend = nil }
                try? await self.send(SendOptions(), reason: .scheduled)
            }
        }
    }

    // MARK: Operations

    public func sendChanges(_ options: SendOptions) async throws {
        try await send(options, reason: .manual)
    }

    public func fetchChanges(_ options: FetchOptions) async throws {
        try await fetch(options, reason: .manual)
    }

    public func fetchRecords(_ records: [RecordID]) async throws -> [RecordChangeData] {
        try await transport.fetchRecords(records)
    }

    public func cancelOperations() async {
        lock.withLock {
            scheduledSend?.cancel()
            scheduledSend = nil
        }
    }

    private func send(_ options: SendOptions, reason: SyncReason) async throws {
        try await gate.run { [self] in
            guard let delegate = lock.withLock({ self.delegate }), try await checkAccount(delegate) else { return }
            try await sendZones(in: options.scope, delegate: delegate)
            let context = SendContext(reason: reason, options: options)
            await delegate.handle(.willSendChanges(context))
            do {
                while let batch = await delegate.nextBatch(context), !batch.isEmpty {
                    let result = try await transport.modifyRecords(batch)
                    let done = result.saved.map { PendingRecordChange.save($0.id, $0.zone) }
                        + result.deleted.map { PendingRecordChange.delete($0.id, $0.zone) }
                    lock.withLock { state.pendingRecords.subtract(done) }
                    await delegate.handle(.sentRecordChanges(result))
                }
            } catch {
                await delegate.handle(.didSendChanges(context))
                await saveState(delegate)
                throw error
            }
            await delegate.handle(.didSendChanges(context))
            await saveState(delegate)
        }
    }

    private func sendZones(in scope: ChangeScope, delegate: any SyncDelegate) async throws {
        let pending = lock.withLock { state.pendingZones.filter { scope.contains($0.zone) } }
        guard !pending.isEmpty else { return }
        var saves: [Zone] = []
        var deletes: [Zone] = []
        for change in pending {
            switch change {
            case .save(let zone): saves.append(zone)
            case .delete(let zone): deletes.append(zone)
            }
        }
        let result = try await transport.modifyZones(save: saves, delete: deletes)
        lock.withLock {
            state.pendingZones.subtract(result.saved.map { .save($0) } + result.deleted.map { .delete($0) })
        }
        await delegate.handle(.sentZoneChanges(result))
    }

    private func fetch(_ requested: FetchOptions, reason: SyncReason) async throws {
        try await gate.run { [self] in
            guard let delegate = lock.withLock({ self.delegate }), try await checkAccount(delegate) else { return }
            var options = requested
            let context = FetchContext(reason: reason, options: requested)
            if reason == .scheduled {
                options = await delegate.nextFetchOptions(context)
            }
            await delegate.handle(.willFetchChanges(context))
            do {
                try await fetchScopes(options, delegate: delegate)
            } catch {
                await delegate.handle(.didFetchChanges(context))
                throw error
            }
            await delegate.handle(.didFetchChanges(context))
        }
    }

    private func fetchScopes(_ options: FetchOptions, delegate: any SyncDelegate) async throws {
        for scope in scopes {
            let token = lock.withLock { state.databaseTokens[scope] }
            let database = try await transport.fetchDatabaseChanges(scope, since: token)
            if !database.deleted.isEmpty || !database.modified.isEmpty {
                lock.withLock {
                    for deletion in database.deleted {
                        state.zoneTokens[deletion.zone] = nil
                    }
                }
                await delegate.handle(.fetchedZoneChanges(modified: database.modified, deleted: database.deleted))
            }
            // Changed zones outside this fetch's scope wait for a later one.
            var zones = lock.withLock {
                state.databaseTokens[scope] = database.token
                let changed = state.unfetchedZones.union(database.modified)
                state.unfetchedZones = changed.filter { !options.scope.contains($0) }
                return changed.filter { options.scope.contains($0) }.sorted { $0.name < $1.name }
            }
            await saveState(delegate)
            zones.sort { a, b in
                let first = options.prioritizedZones.firstIndex(of: a) ?? .max
                let second = options.prioritizedZones.firstIndex(of: b) ?? .max
                return first != second ? first < second : a.name < b.name
            }
            for (index, zone) in zones.enumerated() {
                do {
                    try await fetch(zone, delegate: delegate)
                } catch {
                    // The zones not fetched yet go with the next fetch.
                    lock.withLock { state.unfetchedZones.formUnion(zones[index...]) }
                    throw error
                }
            }
        }
    }

    private func fetch(_ zone: Zone, delegate: any SyncDelegate) async throws {
        await delegate.handle(.willFetchZoneChanges(zone))
        do {
            while true {
                let token = lock.withLock { state.zoneTokens[zone] }
                let page = try await transport.fetchZoneChanges(zone, since: token)
                if !page.saved.isEmpty || !page.deleted.isEmpty {
                    await delegate.handle(.fetchedRecordChanges(saved: page.saved, deleted: page.deleted))
                }
                // The token is stored after the changes, so a crash between them fetches them again.
                lock.withLock { state.zoneTokens[zone] = page.token }
                await saveState(delegate)
                guard page.moreComing, !(page.saved.isEmpty && page.deleted.isEmpty) else { break }
            }
        } catch {
            await delegate.handle(.didFetchZoneChanges(zone, error as? SyncFailure ?? .other("\(error)")))
            throw error
        }
        await delegate.handle(.didFetchZoneChanges(zone, nil))
    }

    // MARK: Account

    /// Reports an account change, and returns whether someone is signed in.
    private func checkAccount(_ delegate: any SyncDelegate) async throws -> Bool {
        let user = try await transport.currentUser()
        let change: AccountChange? = lock.withLock {
            let known = state.knowsUser
            let previous = state.user
            guard !known || previous != user else { return nil }
            state.knowsUser = true
            state.user = user
            // Another account's tokens and pending changes mean nothing to this one.
            if known {
                state.databaseTokens = [:]
                state.zoneTokens = [:]
                state.pendingRecords = []
            }
            switch (previous, user) {
            case (_, nil): return .signOut(previousUser: previous)
            case (nil, let user?): return .signIn(user: user)
            case (let previous?, let user?): return .switchAccounts(from: previous, to: user)
            }
        }
        if let change {
            await delegate.handle(.accountChange(change))
            await saveState(delegate)
        }
        return user != nil
    }

    private func saveState(_ delegate: any SyncDelegate) async {
        let data = lock.withLock { try? JSONEncoder().encode(state) }
        guard let data else { return }
        for scope in scopes {
            await delegate.handle(.stateUpdate(scope, data))
        }
    }
}

/// Runs operations one at a time, in the order they arrive.
private actor OperationGate {
    private var tail: Task<Void, Never>?

    func run(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task {
            await previous?.value
            try await body()
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}
