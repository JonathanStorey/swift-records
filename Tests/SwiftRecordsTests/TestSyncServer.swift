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
    /// Goes up with each `reset()`, so providers can tell the zone was deleted.
    private(set) var epoch = 0

    /// The signed-in account. Private zones keep each account's records apart.
    var account: String? = "alice"
    var isOnline = true
    var isFull = false
    var rejectedTypes: Set<String> = []
    /// Zones every account shares. Only a record's owner can change it.
    var publicZones: Set<Zone> = []

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Where a zone's records live: shared for a public zone, otherwise the account's own.
    private func space(_ zone: Zone, account: String?) -> String {
        "\(publicZones.contains(zone) ? "public" : account ?? "")|\(zone)|"
    }

    private func key(_ zone: Zone, _ type: String, _ id: UUID, account: String?) -> String {
        space(zone, account: account) + "\(type)|\(id)"
    }

    /// Strictly later for each change.
    private static func date(_ sequence: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
    }

    /// Stores a change from `user`, or answers with the newer copy it conflicts with.
    func save(_ change: RecordChangeData, by user: String?) -> UploadResult {
        withLock {
            let storageKey = key(change.zone, change.type, change.id, account: user)
            let current = latest[storageKey]?.change
            if !change.isDeletion, let current, current.synced != change.synced {
                return .conflict(current)
            }
            var stored = change
            if publicZones.contains(change.zone) {
                if let owner = current?.owner, owner != user {
                    return .rejected(id: change.id)
                }
                // The server, not the device, decides who owns a new record.
                stored = Self.owned(change, by: current?.owner ?? user)
            }
            sequence += 1
            let date = Self.date(sequence)
            latest[storageKey] = (stored.syncing(at: date), sequence)
            return .synced(id: change.id, at: date)
        }
    }

    private static func owned(_ change: RecordChangeData, by owner: String?) -> RecordChangeData {
        switch change {
        case .save(let id, let zone, let type, let json, _, let synced):
            .save(id: id, zone: zone, type: type, json: json, owner: owner, synced: synced)
        case .delete(let id, let zone, let type, _, let synced):
            .delete(id: id, zone: zone, type: type, owner: owner, synced: synced)
        }
    }

    /// Stores a record as if another device had saved it.
    func put(_ type: String, id: UUID = UUID(), zone: Zone = .default, json: String) {
        let change = RecordChangeData.save(id: id, zone: zone, type: type, json: Data(json.utf8), owner: nil, synced: nil)
        withLock {
            sequence += 1
            latest[key(zone, type, id, account: account)] = (change.syncing(at: Self.date(sequence)), sequence)
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

    /// The stored JSON of a record the current account can see.
    func record(_ type: String, _ id: UUID, zone: Zone = .default) -> RecordChangeData? {
        withLock { latest[key(zone, type, id, account: account)]?.change }
    }

    /// One field of a stored record, decoded as it crosses the wire.
    func value<T: Decodable>(_ type: String, _ id: UUID, _ field: String, as valueType: T.Type) -> T? {
        guard case .save(_, _, _, let json, _, _)? = record(type, id),
              let member = (try? WireJSON.members(of: json))?[field] else { return nil }
        return try? WireJSON.decoder.decode(T.self, from: member)
    }

    /// Whether a stored record's JSON has the field at all.
    func has(_ type: String, _ id: UUID, _ field: String) -> Bool {
        guard case .save(_, _, _, let json, _, _)? = record(type, id) else { return false }
        return (try? WireJSON.members(of: json))?[field] != nil
    }

    /// Records stored, not counting deletions, across every account.
    var count: Int { withLock { latest.values.filter { !$0.change.isDeletion }.count } }

    func storeAsset(_ data: Data, id: String) {
        withLock { assets[id] = data }
    }

    func asset(_ id: String) -> Data? {
        withLock { assets[id] }
    }

    /// Deletes everything, as when a person deletes the app's data in Settings.
    func reset() {
        withLock {
            latest = [:]
            assets = [:]
            epoch += 1
        }
    }
}

/// A provider that talks to a `TestServer`.
final class TestProvider: SyncProvider, @unchecked Sendable {
    let server: TestServer
    private let lock = NSLock()
    private var batches: [[RecordChangeData]] = []
    private var uploadedAssets: [String] = []
    private var epoch: Int
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
        epoch = server.withLock { server.epoch }
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
        let (online, current) = server.withLock { (server.isOnline, server.epoch) }
        guard online else { throw SyncError.offline }
        let reset = lock.withLock {
            defer { epoch = current }
            return epoch != current
        }
        if reset { throw SyncError.serverReset }
    }

    func userID() async throws -> String? {
        user
    }

    func uploadRecordChanges(_ changes: [RecordChangeData]) async throws -> [UploadResult] {
        lock.withLock { batches.append(changes) }
        try check()
        let (full, rejected) = server.withLock { (server.isFull, server.rejectedTypes) }
        guard !full else { throw SyncError.storageFull }
        let user = user
        let results: [UploadResult] = changes.map { change in
            rejected.contains(change.type) ? .rejected(id: change.id) : server.save(change, by: user)
        }
        // Saved, but the app never hears back, however often it sends again.
        return dropsAcknowledgements ? [] : results
    }

    func downloadRecordChanges(in zone: Zone, after cursor: Data?) async throws -> RecordDownload {
        try check()
        let start = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let page = server.changes(in: zone, for: user, since: start, limit: pageSize)
        return RecordDownload(changes: page.changes, cursor: Data(String(page.cursor).utf8), hasMore: page.hasMore)
    }

    func uploadAssets(_ assets: [RecordAssetData]) async throws {
        try check()
        guard !failsAssetUploads else { throw SyncError.offline }
        for asset in assets {
            server.storeAsset(try Data(contentsOf: asset.file), id: asset.id)
            lock.withLock { uploadedAssets.append(asset.id) }
        }
    }

    func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL {
        await beforeAssetDownload?()
        try check()
        guard let data = server.asset(id) else { throw SyncError.offline }
        let file = directory.appendingPathComponent(id)
        try data.write(to: file)
        return file
    }
}
