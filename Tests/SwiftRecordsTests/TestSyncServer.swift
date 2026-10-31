import Foundation
@testable import SwiftRecords

/// A stand-in sync server that several in-memory containers share, each playing one device. It checks
/// `synced` dates the way the protocol asks: a save based on an older copy comes back as a conflict.
final class TestServer: @unchecked Sendable {
    /// Tells servers apart, as a provider's URL would.
    let name = UUID().uuidString
    private let lock = NSLock()
    /// Each record's latest change, deletions included, with the sequence number it was stored at.
    private var latest: [String: (change: RecordChangeData, sequence: Int)] = [:]
    private var assets: [String: Data] = [:]
    private var sequence = 0
    /// Goes up with each `reset(reason:)`, so devices can tell the zones were deleted.
    private(set) var epoch = 0
    /// Why the last reset happened.
    private(set) var resetReason = ZoneDeletion.Reason.purged

    /// The signed-in account. Zones keep each account's records apart.
    var account: String? = "alice"
    var isOnline = true
    var isFull = false
    var rejectedTypes: Set<String> = []
    /// Whether the server versions records with tags. Without them, every save simply overwrites.
    var tagsRecords = true
    /// Whether the server says when it saved each copy.
    var datesRecords = true

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Where a zone's records live: the account's own.
    private func space(_ zone: Zone, account: String?) -> String {
        "\(account ?? "")|\(zone)|"
    }

    private func key(_ zone: Zone, _ type: String, _ id: UUID, account: String?) -> String {
        space(zone, account: account) + "\(type)|\(id)"
    }

    /// Strictly later for each change.
    private static func date(_ sequence: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
    }

    /// Stores a change from `user`, and returns the stored copy, or the newer copy it conflicts with.
    func save(_ change: RecordChangeData, by user: String?) -> Result<RecordChangeData, SyncFailure> {
        withLock {
            let storageKey = key(change.zone, change.type, change.id, account: user)
            let current = latest[storageKey]?.change
            if tagsRecords, !change.isDeletion, let current, current.tag != change.tag {
                return .failure(.serverRecordChanged(current))
            }
            sequence += 1
            var stored = change
            stored.tag = tagsRecords ? Data("tag \(sequence)".utf8) : nil
            stored.synced = datesRecords ? Self.date(sequence) : nil
            latest[storageKey] = (stored, sequence)
            return .success(stored)
        }
    }

    /// Stores a record as if another device had saved it.
    func put(_ type: String, id: UUID = UUID(), zone: Zone = .default, fields: [String: RecordValue]) {
        withLock {
            sequence += 1
            let change = RecordChangeData(
                id: id, zone: zone, type: type, fields: fields, tag: tagsRecords ? Data("tag \(sequence)".utf8) : nil,
                synced: datesRecords ? Self.date(sequence) : nil
            )
            latest[key(zone, type, id, account: account)] = (change, sequence)
        }
    }

    /// The zones `user` has records in, those with changes after `cursor`, and the latest sequence number.
    func zones(for user: String?, changedAfter cursor: Int) -> (all: Set<Zone>, changed: Set<Zone>, sequence: Int) {
        withLock {
            let own = latest.filter { $0.key.hasPrefix("\(user ?? "")|") }.values
            return (Set(own.map(\.change.zone)), Set(own.filter { $0.sequence > cursor }.map(\.change.zone)), sequence)
        }
    }

    /// The zone's latest changes for `user` after `cursor`, oldest first, at most `limit`, and the new cursor.
    func changes(in zone: Zone, for user: String?, since cursor: Int, limit: Int) -> (changes: [RecordChangeData], cursor: Int, hasMore: Bool) {
        withLock {
            let prefix = space(zone, account: user)
            let found = latest.filter { $0.key.hasPrefix(prefix) && $0.value.sequence > cursor }.values.sorted { $0.sequence < $1.sequence }
            let page = found.prefix(limit)
            return (page.map(\.change), page.last?.sequence ?? cursor, found.count > limit)
        }
    }

    /// The stored copy of a record the current account can see.
    func record(_ type: String, _ id: UUID, zone: Zone = .default) -> RecordChangeData? {
        withLock { latest[key(zone, type, id, account: account)]?.change }
    }

    /// One field of a stored record, as it crosses the wire.
    func value(_ type: String, _ id: UUID, _ field: String) -> RecordValue? {
        record(type, id)?.fields?[field]
    }

    /// The ID of the asset file a stored record's field points to.
    func assetID(_ type: String, _ id: UUID, _ field: String) -> String? {
        guard case .asset(let asset)? = value(type, id, field) else { return nil }
        return asset
    }

    /// Whether a stored record has the field at all.
    func has(_ type: String, _ id: UUID, _ field: String) -> Bool {
        value(type, id, field) != nil
    }

    /// The stored records of a type, not counting deletions, across every account.
    func records(_ type: String) -> [RecordChangeData] {
        withLock { latest.values.map(\.change).filter { $0.type == type && !$0.isDeletion } }
    }

    /// Records stored, not counting deletions, across every account.
    var count: Int { withLock { latest.values.filter { !$0.change.isDeletion }.count } }

    func storeAsset(_ data: Data, id: String) {
        withLock { assets[id] = data }
    }

    func asset(_ id: String) -> Data? {
        withLock { assets[id] }
    }

    /// Deletes everything, as when a person deletes the app's data in Settings, or for `.encryptedDataReset`,
    /// when the server loses it.
    func reset(reason: ZoneDeletion.Reason = .purged) {
        withLock {
            latest = [:]
            assets = [:]
            epoch += 1
            resetReason = reason
        }
    }
}

/// A transport that talks to a `TestServer`, as one device.
final class TestTransport: SyncTransport, AssetTransfer, @unchecked Sendable {
    let server: TestServer
    private let lock = NSLock()
    private var batches: [[RecordChangeData]] = []
    private var uploadedAssets: [String] = []
    /// Saves on the server without answering, as if the app quit before hearing back.
    var dropsAcknowledgements = false
    /// Signs this device in as someone other than the server's account, `.some(nil)` for signed out.
    var account: String??
    /// Changes per download page.
    var pageSize = 100
    /// Fails every asset upload, as if the connection dropped mid-file.
    var failsAssetUploads = false
    /// Runs before each asset download.
    var beforeAssetDownload: (@Sendable () async -> Void)?

    var identifier: String { server.name }

    init(server: TestServer, account: String?? = nil) {
        self.server = server
        self.account = account
    }

    /// Every batch the container asked to upload.
    var sentBatches: [[RecordChangeData]] { lock.withLock { batches } }

    /// Every asset file uploaded, by ID.
    var sentAssets: [String] { lock.withLock { uploadedAssets } }

    private var user: String? {
        lock.withLock { account } ?? server.withLock { server.account }
    }

    /// Throws what a real server would before doing any work.
    private func check() throws {
        guard server.withLock({ server.isOnline }) else { throw SyncFailure.networkUnavailable }
    }

    func currentUser() async throws -> String? {
        user
    }

    func modifyRecords(_ batch: RecordBatch) async throws -> SentRecordChanges {
        let changes = batch.changes
        lock.withLock { batches.append(changes) }
        try check()
        let (full, rejected) = server.withLock { (server.isFull, server.rejectedTypes) }
        guard !full else { throw SyncFailure.quotaExceeded }
        let user = user
        var result = SentRecordChanges()
        for change in changes {
            if rejected.contains(change.type) {
                result.failed.append(FailedSave(change: change, failure: .permissionFailure))
                continue
            }
            switch server.save(change, by: user) {
            case .success(let stored):
                if change.isDeletion {
                    result.deleted.append(RecordDeletion(id: change.id, zone: change.zone, type: change.type))
                } else {
                    result.saved.append(stored)
                }
            case .failure(let failure):
                result.failed.append(FailedSave(change: change, failure: failure))
            }
        }
        // Saved, but the app never hears back, however often it sends again.
        return dropsAcknowledgements ? SentRecordChanges() : result
    }

    /// The token holds the server's epoch, the last sequence seen, and the zones seen, so a reset reads as
    /// those zones being deleted.
    private struct DatabaseToken: Codable {
        var epoch: Int
        var sequence: Int
        var zones: [Zone]
    }

    func fetchDatabaseChanges(_ scope: Zone.Scope, since token: Data?) async throws -> DatabaseChanges {
        try check()
        let (epoch, reason) = server.withLock { (server.epoch, server.resetReason) }
        var known = token.flatMap { try? JSONDecoder().decode(DatabaseToken.self, from: $0) }
        var deleted: [ZoneDeletion] = []
        if let old = known, old.epoch != epoch {
            deleted = old.zones.map { ZoneDeletion(zone: $0, reason: reason) }
            known = nil
        }
        let zones = server.zones(for: user, changedAfter: known?.sequence ?? 0)
        let seen = Set(known?.zones ?? []).union(zones.all)
        let next = DatabaseToken(epoch: epoch, sequence: zones.sequence, zones: seen.sorted { $0.name < $1.name })
        return DatabaseChanges(
            modified: zones.changed.sorted { $0.name < $1.name }, deleted: deleted, token: try JSONEncoder().encode(next)
        )
    }

    func fetchZoneChanges(_ zone: Zone, since token: Data?) async throws -> ZoneChanges {
        try check()
        let start = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let page = server.changes(in: zone, for: user, since: start, limit: pageSize)
        return ZoneChanges(
            saved: page.changes.filter { !$0.isDeletion },
            deleted: page.changes.filter(\.isDeletion).map { RecordDeletion(id: $0.id, zone: $0.zone, type: $0.type) },
            token: Data(String(page.cursor).utf8), moreComing: page.hasMore
        )
    }

    func uploadAssets(_ assets: [RecordAssetData]) async throws {
        try check()
        guard !failsAssetUploads else { throw SyncFailure.networkUnavailable }
        for asset in assets {
            server.storeAsset(try Data(contentsOf: asset.file), id: asset.id)
            lock.withLock { uploadedAssets.append(asset.id) }
        }
    }

    func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL {
        await beforeAssetDownload?()
        try check()
        guard let data = server.asset(id) else { throw SyncFailure.networkUnavailable }
        let file = directory.appendingPathComponent(id)
        try data.write(to: file)
        return file
    }
}

/// One device's engine on a `TestServer`, which syncs only when asked so tests control each step.
final class TestProvider: SyncProvider, @unchecked Sendable {
    let transport: TestTransport
    private let engine: PollingSyncEngine

    init(server: TestServer, account: String?? = nil, automaticallySync: Bool = false) {
        transport = TestTransport(server: server, account: account)
        engine = PollingSyncEngine(transport: transport, automaticallySync: automaticallySync, sendDelay: .milliseconds(10))
    }

    var server: TestServer { transport.server }
    var sentBatches: [[RecordChangeData]] { transport.sentBatches }
    var sentAssets: [String] { transport.sentAssets }

    var dropsAcknowledgements: Bool {
        get { transport.dropsAcknowledgements }
        set { transport.dropsAcknowledgements = newValue }
    }

    var account: String?? {
        get { transport.account }
        set { transport.account = newValue }
    }

    var pageSize: Int {
        get { transport.pageSize }
        set { transport.pageSize = newValue }
    }

    var failsAssetUploads: Bool {
        get { transport.failsAssetUploads }
        set { transport.failsAssetUploads = newValue }
    }

    var beforeAssetDownload: (@Sendable () async -> Void)? {
        get { transport.beforeAssetDownload }
        set { transport.beforeAssetDownload = newValue }
    }

    // MARK: SyncProvider

    var identifier: String { engine.identifier }
    var assetTransfer: (any AssetTransfer)? { engine.assetTransfer }

    func start(_ scope: Zone.Scope, state: Data?, delegate: any SyncDelegate) async {
        await engine.start(scope, state: state, delegate: delegate)
    }

    func addPending(_ changes: [PendingRecordChange]) { engine.addPending(changes) }
    func removePending(_ changes: [PendingRecordChange]) { engine.removePending(changes) }
    func addPending(_ changes: [PendingZoneChange]) { engine.addPending(changes) }
    func removePending(_ changes: [PendingZoneChange]) { engine.removePending(changes) }
    func sendChanges(_ options: SendOptions) async throws { try await engine.sendChanges(options) }
    func fetchChanges(_ options: FetchOptions) async throws { try await engine.fetchChanges(options) }
    func cancelOperations() async { await engine.cancelOperations() }
}
