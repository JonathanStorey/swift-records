import Foundation

/// One zone's side of sync: where it stands, its asset transfers, and the calls its contexts make. The
/// container's `SyncHub` does the work with the engine.
final class ZoneSync: @unchecked Sendable {
    /// Where syncing stands, which a context combines with its own saves into `status`.
    enum Phase: Sendable, Hashable {
        case idle
        case syncing
        case offline
        case signedOut
        case failed(RecordsError)
    }

    /// How far the current asset transfers have got, by file count.
    struct Transfer: Sendable, Hashable {
        var done: Int
        var total: Int
    }

    private static let accountKey = "provider.account"
    private static let identifierKey = "provider.identifier"
    private static let refetchKey = "provider.refetch"

    let zone: Zone
    let store: RecordStore
    private let hub: SyncHub
    private let phaseChanged: @Sendable (Phase) -> Void
    /// Reports transfer progress, `nil` when none are running, and whether a downloaded file just landed.
    private let transferChanged: @Sendable (Transfer?, _ landed: Bool) async -> Void
    /// Whether a context is showing the zone, so its changes are fetched first.
    private let shown: @Sendable () -> Bool

    private let lock = NSLock()
    private var phase: Phase = .idle
    /// What went wrong in the sync running now, which ends in `failed`.
    private var failure: RecordsError?
    private var offline = false
    private var signedOut = false
    private var prepared = false
    private var commitObserver: UUID?
    /// The asset transfers running now, and whether a sync has finished since they started.
    private var transferring: Task<Void, Never>?
    private var transferRequested = false

    init(
        zone: Zone, store: RecordStore, hub: SyncHub,
        phaseChanged: @escaping @Sendable (Phase) -> Void,
        transferChanged: @escaping @Sendable (Transfer?, _ landed: Bool) async -> Void = { _, _ in },
        shown: @escaping @Sendable () -> Bool = { false }
    ) {
        self.zone = zone
        self.store = store
        self.hub = hub
        self.phaseChanged = phaseChanged
        self.transferChanged = transferChanged
        self.shown = shown
        hub.registry.add(self)
        // Each commit's changes are pending, which the engine hears of.
        commitObserver = store.observeCommits { [weak self, weak hub] in
            guard let self, let hub else { return }
            Task { await hub.registerPending(self) }
        }
    }

    deinit {
        if let commitObserver {
            store.removeCommitObserver(commitObserver)
        }
    }

    var isShown: Bool { shown() }

    // MARK: Calls from contexts

    /// Retries records an earlier version couldn't store, then sends what is pending.
    func open() async {
        await hub.open(self)
    }

    /// Sends what is pending.
    func send() async {
        await hub.send(self)
    }

    /// Sends, then fetches the server's changes. Throws the error that ends in `failed`.
    func refresh() async throws {
        await hub.refresh(self)
        if case .failed(let error) = lock.withLock({ phase }) {
            throw error
        }
    }

    /// Fetches the server's changes without sending first.
    func download() async {
        await hub.download(self)
    }

    /// Waits for the asset transfers running now, and any a finished sync has asked for.
    func transfers() async {
        while let transferring = lock.withLock({ transferring }) {
            await transferring.value
        }
    }

    // MARK: Phase

    private func setPhase(_ new: Phase) {
        let changed = lock.withLock {
            defer { phase = new }
            return phase != new
        }
        if changed { phaseChanged(new) }
    }

    /// Starts a sync: clears what went wrong in the last one.
    func begin() {
        lock.withLock {
            failure = nil
            offline = false
        }
        markSyncing()
    }

    /// Shows `syncing`, unless a record that won't decode is being reported or no one is signed in.
    func markSyncing() {
        let keep = lock.withLock {
            if signedOut { return true }
            if case .failed(.incompatibleRecord) = phase { return true }
            return false
        }
        if !keep { setPhase(.syncing) }
    }

    func markOffline() {
        lock.withLock { offline = true }
    }

    func fail(_ error: RecordsError) {
        lock.withLock { failure = error }
    }

    /// Ends a sync in the phase what happened calls for, then moves asset files.
    func finish(error: (any Error)?, signedOut: Bool) {
        let (failure, offline, current) = lock.withLock { (self.failure, self.offline, phase) }
        let new: Phase
        if let error {
            if let failure = error as? SyncFailure, failure == .quotaExceeded {
                new = .failed(.storageFull)
            } else if let error = error as? RecordsError {
                new = .failed(error)
            } else {
                new = .offline
            }
        } else {
            if signedOut {
                new = .signedOut
            } else if let failure {
                new = .failed(failure)
            } else if case .failed(.incompatibleRecord) = current {
                // A record that won't decode stays reported.
                new = current
            } else {
                new = offline ? .offline : .idle
            }
        }
        setPhase(new)
        startTransfers()
    }

    func setSignedOut(_ value: Bool) {
        lock.withLock { signedOut = value }
        if value {
            setPhase(.signedOut)
        } else if lock.withLock({ phase }) == .signedOut {
            setPhase(.idle)
        }
    }

    // MARK: Records

    /// Retries records an earlier version of the app couldn't store, and forgets the old server's account
    /// when the provider is a new one, so the next sign-in uploads everything to it. Runs once.
    func prepare(identifier: String) {
        let first = lock.withLock {
            defer { prepared = true }
            return !prepared
        }
        guard first else { return }
        if let parked = (try? store.retryParked())?.first {
            fail(.incompatibleRecord(type: parked.type, id: parked.id))
            setPhase(.failed(.incompatibleRecord(type: parked.type, id: parked.id)))
        }
        let stored = (try? store.syncValue(forKey: Self.identifierKey)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }
        guard stored != identifier else { return }
        if stored != nil {
            try? store.setSyncValue(nil, forKey: Self.accountKey)
        }
        try? store.setSyncValue(Data(identifier.utf8), forKey: Self.identifierKey)
    }

    /// Brings the zone in line with the signed-in account. A first sign-in uploads everything here.
    /// Another account's records leave this device, so they never reach this one's data.
    func applyAccount(_ user: String) {
        let stored = (try? store.syncValue(forKey: Self.accountKey)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }
        guard stored != user else { return }
        if stored == nil {
            keepLocalData()
        } else {
            deleteLocalData()
        }
        try? store.setSyncValue(Data(user.utf8), forKey: Self.accountKey)
    }

    /// Makes every record pending, to upload as if new.
    func keepLocalData() {
        do {
            try store.markAllPending()
        } catch {
            fail(Self.recordsError(error))
        }
    }

    /// Deletes the records on this device. The account and server it synced with are kept.
    func deleteLocalData() {
        let account = try? store.syncValue(forKey: Self.accountKey)
        let identifier = try? store.syncValue(forKey: Self.identifierKey)
        do {
            try store.deleteAllData()
            try store.setSyncValue(account ?? nil, forKey: Self.accountKey)
            try store.setSyncValue(identifier ?? nil, forKey: Self.identifierKey)
        } catch {
            fail(Self.recordsError(error))
        }
    }

    /// Applies changes from the server, merging any that have unsent local edits. A partial change this
    /// device lacks the copy for is remembered, to fetch whole.
    func receive(_ changes: [RecordChangeData]) {
        do {
            let received = try store.transaction {
                let received = try store.applyReceived(changes)
                if !received.refetch.isEmpty {
                    try setRefetch(Set(try refetch()).union(received.refetch))
                }
                return received
            }
            if let change = received.incompatible.first {
                fail(.incompatibleRecord(type: change.type, id: change.id))
            }
        } catch {
            fail(Self.recordsError(error))
        }
        placeFiles(of: changes)
    }

    /// Copies in the asset files that came inside records, while they still exist. A file a record here
    /// already has, or that no record uses, is skipped. Views hear once any file lands.
    private func placeFiles(of changes: [RecordChangeData]) {
        let manager = FileManager.default
        var landed = false
        for change in changes {
            for (id, file) in change.assetFiles where !manager.fileExists(atPath: store.assetURL(named: id).path) {
                let copy = manager.temporaryDirectory.appendingPathComponent("SwiftRecords-\(UUID().uuidString)")
                guard (try? manager.copyItem(at: file, to: copy)) != nil else { continue }
                if (try? store.placeDownloadedAsset(at: copy, id: id)) == true {
                    landed = true
                } else {
                    try? manager.removeItem(at: copy)
                }
            }
        }
        if landed {
            let transferChanged = transferChanged
            Task { await transferChanged(nil, true) }
        }
    }

    /// Records to fetch whole, because a partial change built on a copy this device doesn't hold. They're
    /// kept until a fetch brings them, so a failed one is tried again with the next.
    func refetch() throws -> [RecordID] {
        guard let data = try store.syncValue(forKey: Self.refetchKey) else { return [] }
        return (try? JSONDecoder().decode([RecordID].self, from: data)) ?? []
    }

    /// Applies records fetched whole and forgets them.
    func refetched(_ ids: [RecordID], changes: [RecordChangeData]) {
        receive(changes.map { var change = $0; change.changedKeys = nil; change.clearedKeys = []; change.baseTag = nil; return change })
        do {
            try setRefetch(Set(try refetch()).subtracting(ids))
        } catch {
            fail(Self.recordsError(error))
        }
    }

    private func setRefetch(_ ids: Set<RecordID>) throws {
        let sorted = ids.sorted { ($0.type, $0.id.uuidString) < ($1.type, $1.id.uuidString) }
        try store.setSyncValue(sorted.isEmpty ? nil : try JSONEncoder().encode(sorted), forKey: Self.refetchKey)
    }

    /// Records that the server accepted a change.
    func acknowledge(_ change: PendingChange, fields: SyncFields?, tag: Data?, synced: Date?) {
        do {
            try store.transaction { try store.acknowledge(change, sent: fields, tag: tag, synced: synced) }
        } catch {
            fail(Self.recordsError(error))
        }
    }

    private static func recordsError(_ error: any Error) -> RecordsError {
        (RecordsError.mapping(error) as? RecordsError) ?? .database(code: -1, message: "\(error)")
    }

    // MARK: Assets

    private func startTransfers() {
        guard hub.provider.assetTransfer != nil else { return }
        lock.withLock {
            if transferring != nil {
                transferRequested = true
                return
            }
            transferring = Task { await self.transferLoop() }
        }
    }

    private func transferLoop() async {
        while true {
            lock.withLock { transferRequested = false }
            await transferAssets()
            let again = lock.withLock {
                if transferRequested { return true }
                transferring = nil
                return false
            }
            if !again { return }
        }
    }

    /// Uploads the files the server doesn't have, then downloads the ones records here are waiting for,
    /// one file at a time. A file that fails waits for the next sync, as when its record arrived before
    /// the device that made it finished uploading it.
    private func transferAssets() async {
        guard let transfer = hub.provider.assetTransfer else { return }
        let signedOut = lock.withLock { self.signedOut }
        let uploads = signedOut ? [] : (try? store.unsentAssets(zone: zone)) ?? []
        let downloads = signedOut ? [] : (try? store.missingAssets()) ?? []
        var progress = Transfer(done: 0, total: uploads.count + downloads.count)
        guard progress.total > 0 else { return }
        await transferChanged(progress, false)
        for asset in uploads {
            if (try? await transfer.uploadAssets([asset])) != nil {
                try? store.markAssetsUploaded([asset.id])
            }
            progress.done += 1
            await transferChanged(progress, false)
        }
        for id in downloads {
            let landed = (try? await downloadAsset(id, with: transfer)) ?? false
            progress.done += 1
            await transferChanged(progress, landed)
        }
        await transferChanged(nil, false)
    }

    private func downloadAsset(_ id: String, with transfer: any AssetTransfer) async throws -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("SwiftRecords-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let file = try await transfer.downloadAsset(id: id, zone: zone, into: directory)
        return try store.placeDownloadedAsset(at: file, id: id)
    }
}
