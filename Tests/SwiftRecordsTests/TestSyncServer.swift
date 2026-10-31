import Foundation
@testable import SwiftRecords

/// A stand-in sync server that several in-memory containers share, each playing one device. It checks
/// `synced` dates the way the protocol asks: a save based on an older copy comes back as a conflict.
final class TestServer: @unchecked Sendable {
    /// Tells servers apart, as a provider's URL would.
    let name = UUID().uuidString
    private let lock = NSLock()
    /// Each record's latest change, deletions included, with the sequence number it was stored at.
    private var latest: [String: (change: RecordChangeData, sequence: Int, previous: RecordChangeData?)] = [:]
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
    /// Whether downloads carry only the fields that changed since a record's previous copy, as a document
    /// database might. Uploads always apply only their changed fields, so a wrong key list shows up as lost data.
    var sendsPartialChanges = false
    /// How many records devices fetched whole.
    private(set) var fetchedRecords = 0

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Who each owner's zones are shared with, by `owner|zone`.
    private var shares: [String: Set<String>] = [:]

    /// Where a zone's records live: the account's own, or the owner's for a zone shared with it.
    private func space(_ zone: Zone, account: String?) -> String {
        "\(zone.owner ?? account ?? "")|\(zone.name)|"
    }

    /// Shares `owner`'s zone with `user`, who sees it in the shared database.
    func share(_ zone: Zone, of owner: String, with user: String) {
        withLock { shares["\(owner)|\(zone.name)", default: []].insert(user) }
    }

    /// Whether `user` may write to the zone.
    private func mayWrite(_ zone: Zone, _ user: String?) -> Bool {
        guard let owner = zone.owner else { return true }
        return user.map { shares["\(owner)|\(zone.name)"]?.contains($0) ?? false } ?? false
    }

    /// A stored change as `zone` names it, shared or not.
    private static func seen(_ change: RecordChangeData, in zone: Zone) -> RecordChangeData {
        var change = change
        change.zone = zone
        return change
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
            guard mayWrite(change.zone, user) else { return .failure(.permissionFailure) }
            let storageKey = key(change.zone, change.type, change.id, account: user)
            let current = latest[storageKey]?.change
            if tagsRecords, !change.isDeletion, let current, current.tag != change.tag {
                return .failure(.serverRecordChanged(Self.seen(current, in: change.zone)))
            }
            sequence += 1
            var stored = change
            if change.changedKeys != nil, let fields = current?.fields {
                // Only the named fields go up, as with CloudKit.
                var merged = fields
                for key in change.clearedKeys { merged[key] = nil }
                for (key, value) in change.sentFields ?? [:] { merged[key] = value }
                stored.fields = merged
            }
            stored.changedKeys = nil
            stored.clearedKeys = []
            stored.tag = tagsRecords ? Data("tag \(sequence)".utf8) : nil
            stored.synced = datesRecords ? Self.date(sequence) : nil
            // The owner's own zone holds it.
            stored.zone = (try? Zone(change.zone.name)) ?? change.zone
            latest[storageKey] = (stored, sequence, current)
            return .success(Self.seen(stored, in: change.zone))
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
            let storageKey = key(zone, type, id, account: account)
            latest[storageKey] = (change, sequence, latest[storageKey]?.change)
        }
    }

    /// The zones `user` has records in, or that are shared with `user`, those with changes after `cursor`,
    /// and the latest sequence number.
    func zones(for user: String?, in scope: Zone.Scope = .private, changedAfter cursor: Int) -> (all: Set<Zone>, changed: Set<Zone>, sequence: Int) {
        withLock {
            switch scope {
            case .private:
                let own = latest.filter { $0.key.hasPrefix("\(user ?? "")|") }.values
                return (Set(own.map(\.change.zone)), Set(own.filter { $0.sequence > cursor }.map(\.change.zone)), sequence)
            case .shared:
                var all: Set<Zone> = [], changed: Set<Zone> = []
                for (key, users) in shares where user.map(users.contains) ?? false {
                    let parts = key.split(separator: "|").map(String.init)
                    guard let zone = try? Zone(parts[1], sharedBy: parts[0]) else { continue }
                    all.insert(zone)
                    if latest.contains(where: { $0.key.hasPrefix(space(zone, account: user)) && $0.value.sequence > cursor }) {
                        changed.insert(zone)
                    }
                }
                return (all, changed, sequence)
            }
        }
    }

    /// The zone's latest changes for `user` after `cursor`, oldest first, at most `limit`, and the new cursor.
    func changes(in zone: Zone, for user: String?, since cursor: Int, limit: Int) -> (changes: [RecordChangeData], cursor: Int, hasMore: Bool) {
        withLock {
            let prefix = space(zone, account: user)
            let found = latest.filter { $0.key.hasPrefix(prefix) && $0.value.sequence > cursor }.values.sorted { $0.sequence < $1.sequence }
            let page = found.prefix(limit)
            let changes = page.map { Self.seen(sendsPartialChanges ? Self.partial($0.change, since: $0.previous) : $0.change, in: zone) }
            return (changes, page.last?.sequence ?? cursor, found.count > limit)
        }
    }

    /// Only what changed since the previous copy, when there was one.
    private static func partial(_ change: RecordChangeData, since previous: RecordChangeData?) -> RecordChangeData {
        guard let fields = change.fields, let previous, let old = previous.fields, let baseTag = previous.tag else { return change }
        var partial = change
        let changed = Set(fields.compactMap { old[$0.key] == $0.value ? nil : $0.key })
        partial.fields = fields.filter { changed.contains($0.key) }
        partial.changedKeys = changed
        partial.clearedKeys = Set(old.keys.filter { fields[$0] == nil })
        partial.baseTag = baseTag
        return partial
    }

    /// The whole stored copies of records for `user`, and a deletion for each one it doesn't have.
    func wholeRecords(_ ids: [RecordID], for user: String?) -> [RecordChangeData] {
        withLock {
            fetchedRecords += ids.count
            return ids.map {
                latest[key($0.zone, $0.type, $0.id, account: user)].map { [zone = $0.zone] in Self.seen($0.change, in: zone) }
                    ?? RecordChangeData(id: $0.id, zone: $0.zone, type: $0.type, fields: nil)
            }
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
    /// Fails every fetch of whole records, as if the connection dropped.
    var failsRecordFetches = false

    var identifier: String { server.name }

    var scopes: Set<Zone.Scope> { [.private, .shared] }

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
        let zones = server.zones(for: user, in: scope, changedAfter: known?.sequence ?? 0)
        let seen = Set(known?.zones ?? []).union(zones.all)
        let next = DatabaseToken(epoch: epoch, sequence: zones.sequence, zones: seen.sorted { $0.name < $1.name })
        return DatabaseChanges(
            modified: zones.changed.sorted { $0.name < $1.name }, deleted: deleted, token: try JSONEncoder().encode(next)
        )
    }

    func fetchRecords(_ records: [RecordID]) async throws -> [RecordChangeData] {
        try check()
        if failsRecordFetches { throw SyncFailure.networkUnavailable }
        return server.wholeRecords(records, for: user)
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

    var failsRecordFetches: Bool {
        get { transport.failsRecordFetches }
        set { transport.failsRecordFetches = newValue }
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
    var scopes: Set<Zone.Scope> { engine.scopes }
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
    func fetchRecords(_ records: [RecordID]) async throws -> [RecordChangeData] { try await engine.fetchRecords(records) }
}
