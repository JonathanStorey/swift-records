import Foundation

/// Drives a zone's sync provider. Each pass checks the account, uploads pending changes in batches, and
/// with a refresh downloads the server's changes, then works out the sync part of each context's status.
/// Calls that arrive during a pass share the next one. Asset files move separately, in the background
/// after each pass, so records never wait for them.
actor SyncCoordinator {
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

    struct Policies: Sendable {
        var merge: MergePolicy
        var onSignOut: AccountPolicy
        var onAccountSwitch: AccountPolicy
        var onServerReset: AccountPolicy
    }

    private struct Key: Hashable {
        let table: String
        let id: UUID
    }

    static let batchSize = 200
    /// Upload rounds in one pass, so a server that answers every change with a conflict can't keep it going.
    private static let maxRounds = 20
    private static let cursorKey = "provider.cursor"
    private static let accountKey = "provider.account"

    private let provider: any SyncProvider
    private let zone: Zone
    /// Whether everyone shares the zone. Its records carry their owner, signing out doesn't touch them, and
    /// it downloads without an account.
    private let isPublic: Bool
    private let store: RecordStore
    private let policies: Policies
    private let phaseChanged: @Sendable (Phase) -> Void
    /// Reports transfer progress, `nil` when none are running, and whether a downloaded file just landed.
    private let transferChanged: @Sendable (Transfer?, _ landed: Bool) async -> Void

    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { phaseChanged(phase) }
        }
    }

    private var opened = false
    /// The pass running now. Callers that arrive meanwhile ask for another and wait for it.
    private var running: Task<Void, Never>?
    private var passRequested = false
    /// The asset transfers running now, and whether a pass has finished since they started.
    private var transferring: Task<Void, Never>?
    private var transferRequested = false
    private var uploadRequested = false
    private var downloadRequested = false
    private var account: String?
    private var signedOut = false
    /// What went wrong in the pass running now, which ends in `failed`.
    private var failure: RecordsError?

    init(
        provider: any SyncProvider, zone: Zone, isPublic: Bool = false, store: RecordStore, policies: Policies,
        phaseChanged: @escaping @Sendable (Phase) -> Void,
        transferChanged: @escaping @Sendable (Transfer?, _ landed: Bool) async -> Void = { _, _ in }
    ) {
        self.provider = provider
        self.zone = zone
        self.isPublic = isPublic
        self.store = store
        self.policies = policies
        self.phaseChanged = phaseChanged
        self.transferChanged = transferChanged
    }

    // MARK: Calls from contexts

    /// Retries records an earlier version couldn't store, then uploads what is pending.
    func open() async {
        prepare()
        await run(download: false)
    }

    /// Uploads what is pending.
    func send() async {
        prepare()
        await run(download: false)
    }

    /// Uploads what is pending, then downloads the server's changes. Throws the error that ends in `failed`.
    func refresh() async throws {
        prepare()
        await run(download: true)
        if case .failed(let error) = phase {
            throw error
        }
    }

    /// Downloads the server's changes without uploading first.
    func download() async {
        prepare()
        await run(download: true, upload: false)
    }

    /// Downloads after the provider pushes word that the zone changed, then sends any edits the merge left.
    func pushed() async {
        prepare()
        await run(download: true)
    }

    /// Waits for the asset transfers running now, and any a finished pass has asked for.
    func transfers() async {
        while let transferring {
            await transferring.value
        }
    }

    // MARK: Passes

    private func prepare() {
        guard !opened else { return }
        opened = true
        // Records an earlier version of the app couldn't store may fit now.
        if let parked = (try? store.retryParked(policy: policies.merge))?.first {
            phase = .failed(.incompatibleRecord(type: parked.type, id: parked.id))
        }
    }

    private func run(download: Bool, upload: Bool = true) async {
        downloadRequested = downloadRequested || download
        uploadRequested = uploadRequested || upload
        if let running {
            passRequested = true
            await running.value
            return
        }
        let task = Task { await self.loop() }
        running = task
        await task.value
    }

    private func loop() async {
        var passes = 0
        repeat {
            passes += 1
            passRequested = false
            let download = downloadRequested
            let upload = uploadRequested
            downloadRequested = false
            uploadRequested = false
            await pass(download: download, upload: upload)
        } while passRequested && passes < Self.maxRounds
        running = nil
        startTransfers()
    }

    private func pass(download: Bool, upload: Bool) async {
        failure = nil
        do {
            guard try await checkAccount() else { return }
            if upload, !signedOut {
                try await uploadPending()
            }
            if download {
                try await downloadChanges()
                // Merging with the server's copies leaves edits to send.
                if upload, !signedOut, !((try? store.pendingChanges()) ?? []).isEmpty {
                    try await uploadPending()
                }
            }
            if let failure {
                phase = .failed(failure)
            } else if case .failed(.incompatibleRecord) = phase {
                // A record that won't decode stays reported.
            } else {
                phase = .idle
            }
        } catch SyncError.serverReset {
            apply(policies.onServerReset)
            passRequested = true
            downloadRequested = downloadRequested || download
            uploadRequested = true
        } catch SyncError.storageFull {
            phase = .failed(.storageFull)
        } catch let error as RecordsError {
            phase = .failed(error)
        } catch {
            phase = .offline
        }
    }

    /// Shows `syncing`, unless a record that won't decode is being reported.
    private func markSyncing() {
        if case .failed(.incompatibleRecord) = phase { return }
        phase = .syncing
    }

    // MARK: Uploading

    private func uploadPending() async throws {
        var skipped: Set<Key> = []
        for _ in 0..<Self.maxRounds {
            var batch: [UUID: (change: PendingChange, record: SyncRecord, fields: SyncFields?)] = [:]
            var order: [UUID] = []
            for change in try store.pendingChanges() {
                guard batch.count < Self.batchSize else { break }
                guard !skipped.contains(Key(table: change.table, id: change.id)), batch[change.id] == nil,
                      let (record, fields) = try? store.syncRecord(for: change) else { continue }
                batch[change.id] = (change, record, fields)
                order.append(change.id)
            }
            guard !order.isEmpty else { return }
            markSyncing()
            let records = order.map { batch[$0]!.record }
            let owner = isPublic ? account : nil
            let changes = try records.map { try store.change(for: $0, zone: zone, owner: owner) }
            let results = try await provider.uploadRecordChanges(changes)

            var answered: Set<UUID> = []
            var conflicts: [RecordChangeData] = []
            try store.transaction {
                for result in results {
                    switch result {
                    case .synced(let id, let date):
                        guard let entry = batch[id], answered.insert(id).inserted else { continue }
                        try store.acknowledge(entry.change, sent: entry.fields, synced: date)
                    case .conflict(let server):
                        guard batch[server.id] != nil, answered.insert(server.id).inserted else { continue }
                        conflicts.append(server)
                    case .rejected(let id):
                        guard let entry = batch[id], answered.insert(id).inserted else { continue }
                        skipped.insert(Key(table: entry.change.table, id: id))
                        failure = .rejected(type: entry.change.table, id: id)
                    }
                }
            }
            // Changes the provider didn't answer wait for the next pass.
            for id in order where !answered.contains(id) {
                skipped.insert(Key(table: batch[id]!.change.table, id: id))
            }
            // A conflict's merge stays pending and goes in the next round, based on the server's copy.
            if !conflicts.isEmpty {
                try await receive(conflicts)
            }
        }
    }

    // MARK: Downloading

    private func downloadChanges() async throws {
        markSyncing()
        var cursor = try store.syncValue(forKey: Self.cursorKey)
        while true {
            let page = try await provider.downloadRecordChanges(in: zone, after: cursor)
            try await receive(page.changes, cursor: page.cursor)
            cursor = page.cursor
            guard page.hasMore, !page.changes.isEmpty else { return }
        }
    }

    /// Applies the changes, and the cursor with them. Their asset files follow in the background.
    private func receive(_ changes: [RecordChangeData], cursor: Data? = nil) async throws {
        let incompatible = try store.transaction {
            let incompatible = try store.applyReceived(changes, policy: policies.merge)
            if let cursor {
                try store.setSyncValue(cursor, forKey: Self.cursorKey)
            }
            return incompatible
        }
        if let change = incompatible.first {
            failure = .incompatibleRecord(type: change.type, id: change.id)
        }
    }

    // MARK: Assets

    private func startTransfers() {
        if transferring != nil {
            transferRequested = true
            return
        }
        transferring = Task {
            await self.transferLoop()
        }
    }

    private func transferLoop() async {
        repeat {
            transferRequested = false
            await transferAssets()
        } while transferRequested
        transferring = nil
    }

    /// Uploads the files the server doesn't have, then downloads the ones records here are waiting for,
    /// one file at a time. A file that fails waits for the next pass, as when its record arrived before
    /// the device that made it finished uploading it.
    private func transferAssets() async {
        let uploads = signedOut ? [] : (try? store.unsentAssets(zone: zone)) ?? []
        let downloads = signedOut && !isPublic ? [] : (try? store.missingAssets()) ?? []
        var progress = Transfer(done: 0, total: uploads.count + downloads.count)
        guard progress.total > 0 else { return }
        await transferChanged(progress, false)
        for asset in uploads {
            if (try? await provider.uploadAssets([asset])) != nil {
                try? store.markAssetsUploaded([asset.id])
            }
            progress.done += 1
            await transferChanged(progress, false)
        }
        for id in downloads {
            let landed = (try? await downloadAsset(id)) ?? false
            progress.done += 1
            await transferChanged(progress, landed)
        }
        await transferChanged(nil, false)
    }

    private func downloadAsset(_ id: String) async throws -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("SwiftRecords-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let file = try await provider.downloadAsset(id: id, zone: zone, into: directory)
        return try store.placeDownloadedAsset(at: file, id: id)
    }

    // MARK: Accounts

    /// Applies an account change. Returns false when there is nothing to do until someone signs in.
    private func checkAccount() async throws -> Bool {
        let current = try await provider.userID()
        account = current
        let stored = (try? store.syncValue(forKey: Self.accountKey)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }
        guard let current else {
            signedOut = true
            if stored != nil {
                if !isPublic {
                    apply(policies.onSignOut)
                }
                try? store.setSyncValue(nil, forKey: Self.accountKey)
            }
            // Anyone can read a public zone.
            guard isPublic else {
                phase = .signedOut
                return false
            }
            return true
        }
        signedOut = false
        if phase == .signedOut {
            phase = .idle
        }
        guard current != stored else { return true }
        // A first sign-in uploads everything here. Another account's data follows the switch policy.
        if !isPublic {
            apply(stored == nil ? .keepLocalData : policies.onAccountSwitch)
        }
        try? store.setSyncValue(Data(current.utf8), forKey: Self.accountKey)
        return true
    }

    private func apply(_ policy: AccountPolicy) {
        do {
            switch policy {
            case .keepLocalData:
                try store.markAllPending()
            case .deleteLocalData:
                try store.deleteAllData()
            }
            // Whatever the server has is downloaded again from the beginning.
            try store.setSyncValue(nil, forKey: Self.cursorKey)
        } catch {
            phase = .failed(Self.recordsError(error))
        }
    }

    private static func recordsError(_ error: any Error) -> RecordsError {
        (RecordsError.mapping(error) as? RecordsError) ?? .database(code: -1, message: "\(error)")
    }
}
