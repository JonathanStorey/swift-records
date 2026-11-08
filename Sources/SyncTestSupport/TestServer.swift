import Foundation
import SwiftRecords

/// A stand-in sync server that several in-memory containers share, each playing one device. It checks
/// `synced` dates the way the protocol asks: a save based on an older copy comes back as a conflict.
package final class TestServer: @unchecked Sendable {
    /// Tells servers apart, as a provider's URL would.
    package let name = UUID().uuidString
    private let lock = NSLock()
    /// Each record's latest change, deletions included, with the sequence number it was stored at.
    private var latest: [String: (change: RecordChangeData, sequence: Int, previous: RecordChangeData?)] = [:]
    private var assets: [String: Data] = [:]
    private var sequence = 0
    /// Goes up with each `reset(reason:)`, so devices can tell the zones were deleted.
    package private(set) var epoch = 0
    /// Why the last reset happened.
    package private(set) var resetReason = ZoneDeletion.Reason.purged

    /// The signed-in account. Zones keep each account's records apart.
    package var account: String? = "alice"
    package var isOnline = true
    package var isFull = false
    package var rejectedTypes: Set<String> = []
    /// Refuses a save whose `.deleteSelf` reference names a record neither stored nor in the same batch, as
    /// CloudKit does.
    package var checksReferences = false

    package init() {}

    package func withLock<T>(_ body: () throws -> T) rethrows -> T {
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
    package func share(_ zone: Zone, of owner: String, with user: String) {
        withLock { shares["\(owner)|\(zone.name)", default: []].insert(user) }
    }

    /// Stops sharing `owner`'s zone with `user`, or with everyone.
    package func unshare(_ zone: Zone, of owner: String, with user: String? = nil) {
        withLock {
            let key = "\(owner)|\(zone.name)"
            if let user {
                shares[key]?.remove(user)
            } else {
                shares[key] = nil
            }
        }
    }

    /// Who `owner`'s zone is shared with, or `nil` when it isn't.
    package func participants(of zone: Zone, owner: String) -> Set<String>? {
        withLock { shares["\(owner)|\(zone.name)"] }
    }

    /// Whether the server holds a record with this ID in the zone.
    package func holds(_ id: UUID, in zone: Zone, by user: String?) -> Bool {
        withLock {
            let prefix = space(zone, account: user)
            return latest.contains { $0.key.hasPrefix(prefix) && $0.key.hasSuffix("|\(id)") && !$0.value.change.isDeletion }
        }
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
    package func save(_ change: RecordChangeData, by user: String?) -> Result<RecordChangeData, SyncFailure> {
        withLock {
            guard mayWrite(change.zone, user) else { return .failure(.permissionFailure) }
            // Files travel inside their records, as `CKAsset`s do.
            for (id, file) in change.assetFiles {
                if let data = try? Data(contentsOf: file) { assets[id] = data }
            }
            let storageKey = key(change.zone, change.type, change.id, account: user)
            let current = latest[storageKey]?.change
            if !change.isDeletion, let current, current.tag != change.tag {
                // The server copy comes with its files, as a `CKRecord` does.
                return .failure(.serverRecordChanged(withFiles(Self.seen(current, in: change.zone))))
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
            stored.assetFiles = [:]
            stored.tag = Data("tag \(sequence)".utf8)
            stored.synced = Self.date(sequence)
            // The owner's own zone holds it.
            stored.zone = (try? Zone(change.zone.name)) ?? change.zone
            latest[storageKey] = (stored, sequence, current)
            return .success(Self.seen(stored, in: change.zone))
        }
    }

    /// Stores a record as if another device had saved it.
    package func put(_ type: String, id: UUID = UUID(), zone: Zone = .default, fields: [String: RecordValue]) {
        withLock {
            sequence += 1
            let change = RecordChangeData(
                id: id, zone: zone, type: type, fields: fields, tag: Data("tag \(sequence)".utf8),
                synced: Self.date(sequence)
            )
            let storageKey = key(zone, type, id, account: account)
            latest[storageKey] = (change, sequence, latest[storageKey]?.change)
        }
    }

    /// The zones `user` has records in, or that are shared with `user`, those with changes after `cursor`,
    /// and the latest sequence number.
    package func zones(for user: String?, in scope: Zone.Scope = .private, changedAfter cursor: Int) -> (all: Set<Zone>, changed: Set<Zone>, sequence: Int) {
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
    package func changes(in zone: Zone, for user: String?, since cursor: Int, limit: Int) -> (changes: [RecordChangeData], cursor: Int, hasMore: Bool) {
        withLock {
            let prefix = space(zone, account: user)
            let found = latest.filter { $0.key.hasPrefix(prefix) && $0.value.sequence > cursor }.values.sorted { $0.sequence < $1.sequence }
            let page = found.prefix(limit)
            let changes = page.map { withFiles(Self.seen($0.change, in: zone)) }
            return (changes, page.last?.sequence ?? cursor, found.count > limit)
        }
    }

    /// A change with its asset files written out, as CloudKit hands over `CKAsset`s.
    private func withFiles(_ change: RecordChangeData) -> RecordChangeData {
        var change = change
        for case .asset(let id) in change.fields?.values.map({ $0 }) ?? [] {
            guard let data = assets[id] else { continue }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("TestServer-\(UUID().uuidString)")
            try? data.write(to: file)
            change.assetFiles[id] = file
        }
        return change
    }

    /// The stored copy of a record the current account can see.
    package func record(_ type: String, _ id: UUID, zone: Zone = .default) -> RecordChangeData? {
        withLock { latest[key(zone, type, id, account: account)]?.change }
    }

    /// One field of a stored record, as it crosses the wire.
    package func value(_ type: String, _ id: UUID, _ field: String) -> RecordValue? {
        record(type, id)?.fields?[field]
    }

    /// The ID of the asset file a stored record's field points to.
    package func assetID(_ type: String, _ id: UUID, _ field: String) -> String? {
        guard case .asset(let asset)? = value(type, id, field) else { return nil }
        return asset
    }

    /// Whether a stored record has the field at all.
    package func has(_ type: String, _ id: UUID, _ field: String) -> Bool {
        value(type, id, field) != nil
    }

    /// The stored records of a type, not counting deletions, across every account.
    package func records(_ type: String) -> [RecordChangeData] {
        withLock { latest.values.map(\.change).filter { $0.type == type && !$0.isDeletion } }
    }

    /// Records stored, not counting deletions, across every account.
    package var count: Int { withLock { latest.values.filter { !$0.change.isDeletion }.count } }

    package func storeAsset(_ data: Data, id: String) {
        withLock { assets[id] = data }
    }

    package func asset(_ id: String) -> Data? {
        withLock { assets[id] }
    }

    /// Deletes everything, as when a person deletes the app's data in Settings, or for `.encryptedDataReset`,
    /// when the server loses it.
    package func reset(reason: ZoneDeletion.Reason = .purged) {
        withLock {
            latest = [:]
            assets = [:]
            epoch += 1
            resetReason = reason
        }
    }
}

/// A transport that talks to a `TestServer`, as one device.
package final class TestTransport: SyncTransport, @unchecked Sendable {
    package let server: TestServer
    private let lock = NSLock()
    private var batches: [[RecordChangeData]] = []
    /// Saves on the server without answering, as if the app quit before hearing back.
    package var dropsAcknowledgements = false
    /// Signs this device in as someone other than the server's account, `.some(nil)` for signed out.
    package var account: String??
    /// Changes per download page.
    package var pageSize = 100

    package var identifier: String { server.name }

    package var scopes: Set<Zone.Scope> { [.private, .shared] }

    package init(server: TestServer, account: String?? = nil) {
        self.server = server
        self.account = account
    }

    /// Every batch the container asked to upload.
    package var sentBatches: [[RecordChangeData]] { lock.withLock { batches } }

    private var user: String? {
        lock.withLock { account } ?? server.withLock { server.account }
    }

    /// Throws what a real server would before doing any work.
    private func check() throws {
        guard server.withLock({ server.isOnline }) else { throw SyncFailure.networkUnavailable }
    }

    package func currentUser() async throws -> String? {
        user
    }

    package func modifyRecords(_ batch: RecordBatch) async throws -> SentRecordChanges {
        let changes = batch.changes
        lock.withLock { batches.append(changes) }
        try check()
        let (full, rejected, checksReferences) = server.withLock { (server.isFull, server.rejectedTypes, server.checksReferences) }
        guard !full else { throw SyncFailure.quotaExceeded }
        let user = user
        var result = SentRecordChanges()
        let inBatch = Set(changes.filter { !$0.isDeletion }.map(\.id))
        for change in changes {
            if rejected.contains(change.type) {
                result.failed.append(FailedSave(change: change, failure: .permissionFailure))
                continue
            }
            if checksReferences, let fields = change.fields, fields.values.contains(where: { value in
                guard case .reference(let target, .deleteSelf) = value else { return false }
                return !inBatch.contains(target) && !server.holds(target, in: change.zone, by: user)
            }) {
                result.failed.append(FailedSave(change: change, failure: .referenceViolation))
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

    package func fetchDatabaseChanges(_ scope: Zone.Scope, since token: Data?) async throws -> DatabaseChanges {
        try check()
        let (epoch, reason) = server.withLock { (server.epoch, server.resetReason) }
        var known = token.flatMap { try? JSONDecoder().decode(DatabaseToken.self, from: $0) }
        var deleted: [ZoneDeletion] = []
        if let old = known, old.epoch != epoch {
            deleted = old.zones.map { ZoneDeletion(zone: $0, reason: reason) }
            known = nil
        }
        let zones = server.zones(for: user, in: scope, changedAfter: known?.sequence ?? 0)
        var seen = Set(known?.zones ?? []).union(zones.all)
        if scope == .shared {
            // A zone no longer shared with the person is gone from their shared database.
            deleted += seen.subtracting(zones.all).sorted { $0.description < $1.description }.map { ZoneDeletion(zone: $0, reason: .deleted) }
            seen = zones.all
        }
        let next = DatabaseToken(epoch: epoch, sequence: zones.sequence, zones: seen.sorted { $0.description < $1.description })
        // A zone joined since the last fetch counts as changed, so the person hears of it.
        let joined = scope == .shared ? zones.all.subtracting(known?.zones ?? []) : []
        return DatabaseChanges(
            modified: zones.changed.union(joined).sorted { $0.description < $1.description }, deleted: deleted,
            token: try JSONEncoder().encode(next)
        )
    }

    package func fetchZoneChanges(_ zone: Zone, since token: Data?) async throws -> ZoneChanges {
        try check()
        let start = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let page = server.changes(in: zone, for: user, since: start, limit: pageSize)
        return ZoneChanges(
            saved: page.changes.filter { !$0.isDeletion },
            deleted: page.changes.filter(\.isDeletion).map { RecordDeletion(id: $0.id, zone: $0.zone, type: $0.type) },
            token: Data(String(page.cursor).utf8), moreComing: page.hasMore
        )
    }

}

extension TestTransport: ZoneSharing {
    /// Invitations read `test://share/<owner>/<zone>`.
    package func share(_ zone: Zone) async throws -> ZoneShare {
        try check()
        guard let owner = user else { throw SyncFailure.permissionFailure }
        if server.participants(of: zone, owner: owner) == nil {
            // An empty share, which people join with the invitation.
            server.share(zone, of: owner, with: owner)
            server.unshare(zone, of: owner, with: owner)
        }
        return try await existingShare(for: zone)!
    }

    package func existingShare(for zone: Zone) async throws -> ZoneShare? {
        try check()
        guard let owner = zone.owner ?? user, let users = server.participants(of: zone, owner: owner) else { return nil }
        let participants = [ShareParticipant(id: owner, role: .owner, status: .accepted)]
            + users.sorted().map { ShareParticipant(id: $0, role: .participant, status: .accepted) }
        let seen = zone.scope == .shared ? zone : try Zone(zone.name)
        return ZoneShare(zone: seen, url: URL(string: "test://share/\(owner)/\(zone.name)"), participants: participants)
    }

    package func acceptShare(_ invitation: URL) async throws -> Zone {
        try check()
        let parts = invitation.pathComponents.filter { $0 != "/" }
        guard invitation.scheme == "test", parts.count == 2, let user,
              let zone = try? Zone(parts[1]), server.participants(of: zone, owner: parts[0]) != nil else {
            throw SyncFailure.other("Not a share")
        }
        server.share(zone, of: parts[0], with: user)
        return try Zone(zone.name, sharedBy: parts[0])
    }

    package func stopSharing(_ zone: Zone) async throws {
        try check()
        if let owner = zone.owner {
            server.unshare(zone, of: owner, with: user)
        } else if let owner = user {
            server.unshare(zone, of: owner)
        }
    }
}

/// One device's engine on a `TestServer`, which syncs only when asked so tests control each step.
package final class TestProvider: SyncProvider, @unchecked Sendable {
    package let transport: TestTransport
    private let engine: PollingSyncEngine

    package init(server: TestServer, account: String?? = nil, automaticallySync: Bool = false) {
        transport = TestTransport(server: server, account: account)
        engine = PollingSyncEngine(transport: transport, automaticallySync: automaticallySync, sendDelay: .milliseconds(10))
    }

    package var server: TestServer { transport.server }
    package var sentBatches: [[RecordChangeData]] { transport.sentBatches }

    package var dropsAcknowledgements: Bool {
        get { transport.dropsAcknowledgements }
        set { transport.dropsAcknowledgements = newValue }
    }

    package var account: String?? {
        get { transport.account }
        set { transport.account = newValue }
    }

    package var pageSize: Int {
        get { transport.pageSize }
        set { transport.pageSize = newValue }
    }

    /// The most changes one upload takes, like CloudKit's size limit.
    package var batchLimit: Int? {
        get { engine.batchLimit }
        set { engine.batchLimit = newValue }
    }

    // MARK: SyncProvider

    package var identifier: String { engine.identifier }
    package var scopes: Set<Zone.Scope> { engine.scopes }
    package var sharing: (any ZoneSharing)? { engine.sharing }

    package func start(_ scope: Zone.Scope, state: Data?, delegate: any SyncDelegate) async {
        await engine.start(scope, state: state, delegate: delegate)
    }

    package func addPending(_ changes: [PendingRecordChange]) { engine.addPending(changes) }
    package func removePending(_ changes: [PendingRecordChange]) { engine.removePending(changes) }
    package var pendingRecordChanges: [PendingRecordChange] { engine.pendingRecordChanges }
    package func addPending(_ changes: [PendingZoneChange]) { engine.addPending(changes) }
    package func removePending(_ changes: [PendingZoneChange]) { engine.removePending(changes) }
    package func sendChanges(_ options: SendOptions) async throws { try await engine.sendChanges(options) }
    package func fetchChanges(_ options: FetchOptions) async throws { try await engine.fetchChanges(options) }
    package func cancelOperations() async { await engine.cancelOperations() }
}
