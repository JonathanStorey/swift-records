import Foundation

/// The sync engine the container drives: `CKSyncEngine` in apps, or the in-memory engine the tests use. The
/// container is its delegate.
///
/// The provider owns scheduling, retries, pushes, change tokens and the account. The container owns the
/// records: it tells the engine what is pending, builds each batch the engine asks for, and applies what
/// the engine reports in `SyncEvent`s. Each requirement names the `CKSyncEngine` API it mirrors, so a
/// CloudKit provider is a thin wrapper.
package protocol SyncProvider: AnyObject, Sendable {
    /// Names the server, such as `"cloudkit:iCloud.com.example.app"`. When it differs from the one a zone
    /// last synced with, the container treats the new server as empty and uploads every local record.
    var identifier: String { get }

    /// The databases this provider serves. CloudKit serves `.private` and `.shared`.
    var scopes: Set<Zone.Scope> { get }

    /// ≈ `CKSyncEngine(_:)`. Called once per scope as the container opens, with the state from the last
    /// `.stateUpdate` for that scope, or `nil` the first time.
    func start(_ scope: Zone.Scope, state: Data?, delegate: any SyncDelegate) async

    /// ≈ `state.add(pendingRecordZoneChanges:)`. Tells the engine these records have changes to send.
    func addPending(_ changes: [PendingRecordChange])

    /// ≈ `state.remove(pendingRecordZoneChanges:)`.
    func removePending(_ changes: [PendingRecordChange])

    /// ≈ `state.add(pendingDatabaseChanges:)`. Zones to create or delete on the server.
    func addPending(_ changes: [PendingZoneChange])

    /// ≈ `state.remove(pendingDatabaseChanges:)`.
    func removePending(_ changes: [PendingZoneChange])

    /// ≈ `sendChanges(_:)`. Sends now rather than when the engine would. Throws `SyncFailure` when the
    /// whole send fails, such as `.networkUnavailable`.
    func sendChanges(_ options: SendOptions) async throws

    /// ≈ `fetchChanges(_:)`. Fetches now rather than when the engine would.
    func fetchChanges(_ options: FetchOptions) async throws

    /// ≈ `cancelOperations()`.
    func cancelOperations() async

    /// Shares the person's zones with other people and joins zones others share. `nil`, the default, means
    /// the provider can't share.
    var sharing: (any ZoneSharing)? { get }

    /// Called once as a container opens with this provider, before syncing starts, for a provider that
    /// converts records with the container's help, as `CloudKitSyncProvider` does. Keep it weakly.
    func attach(_ container: RecordContainer)
}

extension SyncProvider {
    package var scopes: Set<Zone.Scope> { [.private] }

    package var sharing: (any ZoneSharing)? { nil }

    package func attach(_ container: RecordContainer) {}

    package func removePending(_ changes: [PendingRecordChange]) {}

    package func addPending(_ changes: [PendingZoneChange]) {}

    package func removePending(_ changes: [PendingZoneChange]) {}

    package func cancelOperations() async {}
}

/// The engine's delegate. The container implements it, and apps never do. ≈ `CKSyncEngineDelegate`.
package protocol SyncDelegate: AnyObject, Sendable {
    /// ≈ `handleEvent(_:syncEngine:)`. Events for one engine arrive one at a time, in order.
    func handle(_ event: SyncEvent) async

    /// ≈ `nextRecordZoneChangeBatch(_:syncEngine:)`. The next changes to send, or `nil` when nothing in the
    /// context's scope is left to send in this operation.
    func nextBatch(_ context: SendContext) async -> RecordBatch?

    /// ≈ `nextFetchChangesOptions(_:syncEngine:)`. Lets the container put the zones on screen first.
    func nextFetchOptions(_ context: FetchContext) async -> FetchOptions

    /// Hands back records from the last batch that the engine had no room for, so the next batch of the same
    /// send offers them again. ≈ what `RecordZoneChangeBatch(pendingChanges:recordProvider:)` leaves out once
    /// a batch reaches CloudKit's size limit.
    func unsent(_ ids: [UUID]) async
}

/// Something that happened in the engine. ≈ `CKSyncEngine.Event`, one case each.
package enum SyncEvent: Sendable {
    /// The engine's state changed. The container stores it and hands it back to `start`.
    case stateUpdate(Zone.Scope, Data)
    case accountChange(AccountChange)
    case fetchedZoneChanges(modified: [Zone], deleted: [ZoneDeletion])
    case fetchedRecordChanges(saved: [RecordChangeData], deleted: [RecordDeletion])
    case sentZoneChanges(SentZoneChanges)
    case sentRecordChanges(SentRecordChanges)
    case willFetchChanges(FetchContext)
    case willFetchZoneChanges(Zone)
    case didFetchZoneChanges(Zone, SyncFailure?)
    case didFetchChanges(FetchContext)
    case willSendChanges(SendContext)
    case didSendChanges(SendContext)
}

/// A record with changes to send. ≈ `CKSyncEngine.PendingRecordZoneChange`.
package enum PendingRecordChange: Sendable, Hashable, Codable {
    case save(UUID, Zone)
    case delete(UUID, Zone)

    package var id: UUID {
        switch self {
        case .save(let id, _), .delete(let id, _): id
        }
    }

    package var zone: Zone {
        switch self {
        case .save(_, let zone), .delete(_, let zone): zone
        }
    }
}

/// A zone to create or delete on the server. ≈ `CKSyncEngine.PendingDatabaseChange`.
package enum PendingZoneChange: Sendable, Hashable, Codable {
    case save(Zone)
    case delete(Zone)

    package var zone: Zone {
        switch self {
        case .save(let zone), .delete(let zone): zone
        }
    }
}

/// Which records or zones an operation covers. ≈ `CKSyncEngine.SendChangesOptions.Scope`.
package enum ChangeScope: Sendable, Hashable {
    case all
    case zones(Set<Zone>)
    case excludingZones(Set<Zone>)
    case records(Set<UUID>)
    /// Every zone in one database, as each `CKSyncEngine` covers.
    case database(Zone.Scope)

    /// Whether the scope covers a zone at all.
    package func contains(_ zone: Zone) -> Bool {
        switch self {
        case .all, .records: true
        case .database(let scope): zone.scope == scope
        case .zones(let zones): zones.contains(zone)
        case .excludingZones(let zones): !zones.contains(zone)
        }
    }
}

/// ≈ `CKSyncEngine.SendChangesOptions`.
package struct SendOptions: Sendable, Hashable {
    package var scope: ChangeScope

    package init(scope: ChangeScope = .all) {
        self.scope = scope
    }
}

/// ≈ `CKSyncEngine.FetchChangesOptions`.
package struct FetchOptions: Sendable, Hashable {
    package var scope: ChangeScope
    /// Zones to fetch before the others, such as the one on screen.
    package var prioritizedZones: [Zone]

    package init(scope: ChangeScope = .all, prioritizedZones: [Zone] = []) {
        self.scope = scope
        self.prioritizedZones = prioritizedZones
    }
}

/// Why the engine is syncing. ≈ `CKSyncEngine.SyncReason`.
package enum SyncReason: Sendable, Hashable {
    /// The engine decided to, such as after a push or a change.
    case scheduled
    /// Someone called `sendChanges(_:)` or `fetchChanges(_:)`.
    case manual
}

/// ≈ `CKSyncEngine.SendChangesContext`.
package struct SendContext: Sendable, Hashable {
    package let reason: SyncReason
    package let options: SendOptions

    package init(reason: SyncReason, options: SendOptions) {
        self.reason = reason
        self.options = options
    }
}

/// ≈ `CKSyncEngine.FetchChangesContext`.
package struct FetchContext: Sendable, Hashable {
    package let reason: SyncReason
    package let options: FetchOptions

    package init(reason: SyncReason, options: FetchOptions) {
        self.reason = reason
        self.options = options
    }
}

/// Changes to send in one request. ≈ `CKSyncEngine.RecordZoneChangeBatch`. Never atomic by zone, so one
/// conflict fails only its own record.
package struct RecordBatch: Sendable, Hashable {
    package var saves: [RecordChangeData]
    package var deletes: [RecordDeletion]

    package init(saves: [RecordChangeData] = [], deletes: [RecordDeletion] = []) {
        self.saves = saves
        self.deletes = deletes
    }

    package var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }

    /// Every change in the batch, saves first, as a server that takes one list would want them.
    package var changes: [RecordChangeData] {
        saves + deletes.map { RecordChangeData(id: $0.id, zone: $0.zone, type: $0.type, fields: nil, tag: $0.tag) }
    }
}

/// A record deleted, or to delete. ≈ a `CKRecord.ID` with its record type.
package struct RecordDeletion: Sendable, Hashable, Codable {
    package let id: UUID
    package let zone: Zone
    package let type: String
    /// The tag of the copy the deletion is based on, for a server that checks it. CloudKit doesn't.
    package var tag: Data?

    package init(id: UUID, zone: Zone, type: String, tag: Data? = nil) {
        self.id = id
        self.zone = zone
        self.type = type
        self.tag = tag
    }
}

/// What happened to a batch. ≈ `CKSyncEngine.Event.SentRecordZoneChanges`.
package struct SentRecordChanges: Sendable, Hashable {
    /// The server's copies of the saved records, with their new tags and save times. Their fields may be
    /// left out.
    package var saved: [RecordChangeData]
    package var failed: [FailedSave]
    package var deleted: [RecordDeletion]
    package var failedDeletes: [FailedDelete]

    package init(saved: [RecordChangeData] = [], failed: [FailedSave] = [], deleted: [RecordDeletion] = [], failedDeletes: [FailedDelete] = []) {
        self.saved = saved
        self.failed = failed
        self.deleted = deleted
        self.failedDeletes = failedDeletes
    }
}

/// What happened to zone changes. ≈ `CKSyncEngine.Event.SentDatabaseChanges`.
package struct SentZoneChanges: Sendable, Hashable {
    package var saved: [Zone]
    package var failed: [FailedZoneChange]
    package var deleted: [Zone]

    package init(saved: [Zone] = [], failed: [FailedZoneChange] = [], deleted: [Zone] = []) {
        self.saved = saved
        self.failed = failed
        self.deleted = deleted
    }
}

/// ≈ `CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave`.
package struct FailedSave: Sendable, Hashable {
    package let change: RecordChangeData
    package let failure: SyncFailure

    package init(change: RecordChangeData, failure: SyncFailure) {
        self.change = change
        self.failure = failure
    }
}

package struct FailedDelete: Sendable, Hashable {
    package let deletion: RecordDeletion
    package let failure: SyncFailure

    package init(deletion: RecordDeletion, failure: SyncFailure) {
        self.deletion = deletion
        self.failure = failure
    }
}

package struct FailedZoneChange: Sendable, Hashable {
    package let zone: Zone
    package let failure: SyncFailure

    package init(zone: Zone, failure: SyncFailure) {
        self.zone = zone
        self.failure = failure
    }
}

/// ≈ `CKSyncEngine.Event.AccountChange.ChangeType`, with user IDs as text.
package enum AccountChange: Sendable, Hashable {
    /// Someone signed in, or the engine learned who is signed in for the first time.
    case signIn(user: String)
    /// The person signed out. `nil` when the engine never knew anyone, as on a device that was never signed in.
    case signOut(previousUser: String?)
    case switchAccounts(from: String, to: String)
}

/// A zone the server no longer has. ≈ `CKSyncEngine.Event.FetchedDatabaseChanges.Deletion`.
package struct ZoneDeletion: Sendable, Hashable {
    package enum Reason: Sendable, Hashable {
        /// Deleted, such as by the app on another device. Local data goes too.
        case deleted
        /// The person deleted the app's data, such as in Settings. Local data goes too.
        case purged
        /// The server lost the keys to the person's encrypted data. Local data is kept and uploaded again.
        case encryptedDataReset
    }

    package let zone: Zone
    package let reason: Reason

    package init(zone: Zone, reason: Reason) {
        self.zone = zone
        self.reason = reason
    }
}

/// Why a change, or a whole operation, failed. ≈ the `CKError` codes sync has to act on.
package enum SyncFailure: Error, Sendable, Hashable {
    /// The server holds a newer copy, which the container merges and sends again.
    case serverRecordChanged(RecordChangeData)
    /// The record is gone from the server.
    case unknownItem
    /// The zone doesn't exist on the server yet.
    case zoneNotFound
    /// The account is out of storage.
    case quotaExceeded
    /// The network or server can't be reached. Changes stay pending.
    case networkUnavailable
    /// The record is too large to store.
    case limitExceeded
    /// The server refuses the change for good, such as a record someone else owns.
    case permissionFailure
    case other(String)
}

/// One record as it crosses to or from a server, shaped like a `CKRecord`: its values in `fields`, and the
/// server's own data about the copy in `tag`. A deletion has no fields.
///
/// `fields` holds every stored property by name, as CloudKit stores it: a relationship is its records' IDs
/// in order as `.strings`, a child's `@Reference(to:)` is a `.reference`, and an asset is its ID. Treat the
/// fields as opaque where you can: store them and hand them back. Fields from newer app versions are kept
/// and sent back untouched.
///
/// ## Field-level changes
///
/// An upload says which fields it touches: `changedKeys` and `clearedKeys` name the fields that differ from
/// the copy at `tag`, and `fields` still holds the whole record. CloudKit sets only those keys, so an
/// unchanged asset or large field never goes up again. The save still checks `tag`, so conflicts stay
/// whole-record and merge here. A download is always the whole record, as `CKSyncEngine` delivers it.
package struct RecordChangeData: Sendable, Hashable {
    package var id: UUID
    package var zone: Zone
    /// The stored type name, such as `"Recipe"`.
    package var type: String
    /// The record's values, or `nil` for a deletion.
    package var fields: [String: RecordValue]?
    /// The server's data for the copy this change is based on, which only the provider reads: a CloudKit
    /// record's archived system fields, a version number, a hash. `nil` for a copy the server never had,
    /// and always `nil` for a server that doesn't version records.
    package var tag: Data?
    /// When the server saved this copy, if it says. The container stores it as `@Timestamped(.synced)` and
    /// never relies on it.
    package var synced: Date?
    /// The fields set since the copy the change builds on. `nil`: the change is the whole record.
    package var changedKeys: Set<String>?
    /// The fields set to `nil` since the copy the change builds on.
    package var clearedKeys: Set<String>
    /// The files behind this change's `.asset` values, by asset ID. A record and its files travel together,
    /// as CloudKit's `CKAsset`s do: an upload names every file this device has, and a download names the
    /// files that came with it, which the container copies in before the event that carried them ends.
    /// Never encoded.
    package var assetFiles: [String: URL]
    /// The fields of `@Encrypted` properties, which a server that can stores end-to-end encrypted, as
    /// CloudKit does in `encryptedValues`. Set on uploads. A download needs none, since the container knows
    /// its own schema.
    package var encryptedKeys: Set<String>

    package init(
        id: UUID, zone: Zone, type: String, fields: [String: RecordValue]?, tag: Data? = nil, synced: Date? = nil,
        changedKeys: Set<String>? = nil, clearedKeys: Set<String> = [], assetFiles: [String: URL] = [:],
        encryptedKeys: Set<String> = []
    ) {
        self.id = id
        self.zone = zone
        self.type = type
        self.fields = fields
        self.tag = tag
        self.synced = synced
        self.changedKeys = changedKeys
        self.clearedKeys = clearedKeys
        self.assetFiles = assetFiles
        self.encryptedKeys = encryptedKeys
    }

    package var isDeletion: Bool { fields == nil }


    /// The fields an upload sends: only the changed ones, or every one for a whole-record change.
    package var sentFields: [String: RecordValue]? {
        guard let fields, let changedKeys else { return fields }
        return fields.filter { changedKeys.contains($0.key) }
    }
}

extension RecordChangeData: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, zone, type, fields, tag, synced, changedKeys, clearedKeys
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            zone: try container.decode(Zone.self, forKey: .zone),
            type: try container.decode(String.self, forKey: .type),
            fields: try container.decodeIfPresent([String: RecordValue].self, forKey: .fields),
            tag: try container.decodeIfPresent(Data.self, forKey: .tag),
            synced: try container.decodeIfPresent(Date.self, forKey: .synced),
            changedKeys: try container.decodeIfPresent(Set<String>.self, forKey: .changedKeys),
            clearedKeys: try container.decodeIfPresent(Set<String>.self, forKey: .clearedKeys) ?? []
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(zone, forKey: .zone)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(fields, forKey: .fields)
        try container.encodeIfPresent(tag, forKey: .tag)
        try container.encodeIfPresent(synced, forKey: .synced)
        try container.encodeIfPresent(changedKeys.map { $0.sorted() }, forKey: .changedKeys)
        if !clearedKeys.isEmpty {
            try container.encode(clearedKeys.sorted(), forKey: .clearedKeys)
        }
    }
}


/// A field's value as CloudKit holds it, one case for each kind of `CKRecordValue` a record uses.
///
/// It mirrors CloudKit's value types for three jobs: storing records that this app version can't decode yet,
/// which are parked and tried again after an update; keeping fields a newer version added, which go back
/// untouched; and letting the sync logic and its tests run on Linux, where `CKRecord` doesn't exist.
package enum RecordValue: Sendable, Hashable {
    case string(String)
    /// Any integer, and a `Bool` as 0 or 1.
    case int(Int64)
    case double(Double)
    case date(Date)
    /// `Data`, or the JSON of any other `Codable` value.
    case bytes(Data)
    case strings([String])
    case ints([Int64])
    case doubles([Double])
    case dates([Date])
    /// A child's reference to its parent, as a `CKRecord.Reference`.
    case reference(UUID, action: ReferenceAction)
    /// An asset, by its ID. Its file travels with the change, in `assetFiles`.
    case asset(String)
}

extension RecordValue: Codable {
    // A single key names the kind, so a value written to a file reads plainly: {"string":"Soup"}.
    private enum CodingKeys: String, CodingKey {
        case string, int, double, date, bytes, strings, ints, doubles, dates, reference, action, asset
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = container.allKeys.first(where: { $0 != .action }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No value"))
        }
        switch key {
        case .string: self = .string(try container.decode(String.self, forKey: key))
        case .int: self = .int(try container.decode(Int64.self, forKey: key))
        case .double: self = .double(try container.decode(Double.self, forKey: key))
        case .date: self = .date(try container.decode(Date.self, forKey: key))
        case .bytes: self = .bytes(try container.decode(Data.self, forKey: key))
        case .strings: self = .strings(try container.decode([String].self, forKey: key))
        case .ints: self = .ints(try container.decode([Int64].self, forKey: key))
        case .doubles: self = .doubles(try container.decode([Double].self, forKey: key))
        case .dates: self = .dates(try container.decode([Date].self, forKey: key))
        case .reference:
            let action = try container.decodeIfPresent(ReferenceAction.self, forKey: .action) ?? .nullify
            self = .reference(try container.decode(UUID.self, forKey: key), action: action)
        case .asset: self = .asset(try container.decode(String.self, forKey: key))
        case .action: preconditionFailure("Excluded above")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value): try container.encode(value, forKey: .string)
        case .int(let value): try container.encode(value, forKey: .int)
        case .double(let value): try container.encode(value, forKey: .double)
        case .date(let value): try container.encode(value, forKey: .date)
        case .bytes(let value): try container.encode(value, forKey: .bytes)
        case .strings(let value): try container.encode(value, forKey: .strings)
        case .ints(let value): try container.encode(value, forKey: .ints)
        case .doubles(let value): try container.encode(value, forKey: .doubles)
        case .dates(let value): try container.encode(value, forKey: .dates)
        case .reference(let id, let action):
            try container.encode(id, forKey: .reference)
            if action != .nullify { try container.encode(action, forKey: .action) }
        case .asset(let id): try container.encode(id, forKey: .asset)
        }
    }
}

// MARK: - Sharing

/// Shares whole zones between people. ≈ a zone-wide `CKShare`. Apps call it through `RecordContainer`'s
/// `share(_:)`, `acceptShare(_:)` and `stopSharing(_:)`, which also keep the zone's records in step.
///
/// The owner shares one of their private zones and sends the invitation's URL. Each participant who
/// accepts it sees the zone in their `.shared` database, as `Zone(name, sharedBy: owner)`, and syncs it like
/// their own. A provider that shares must serve the `.shared` scope.
package protocol ZoneSharing: AnyObject, Sendable {
    /// Shares one of the person's private zones, or returns the share it already has. The zone and its
    /// records are on the server before this is called.
    func share(_ zone: Zone) async throws -> ZoneShare

    /// The zone's share, or `nil` when it isn't shared. For a zone shared with the person, the owner's share.
    func existingShare(for zone: Zone) async throws -> ZoneShare?

    /// Joins the zone an invitation shares and returns it, as the person will see it in `.shared`.
    func acceptShare(_ invitation: URL) async throws -> Zone

    /// For a private zone, stops sharing it: every participant loses it, and the owner keeps it. For a
    /// shared zone, leaves it.
    func stopSharing(_ zone: Zone) async throws
}

/// A shared zone and who it's shared with. ≈ `CKShare`.
public struct ZoneShare: Sendable, Hashable {
    /// The zone as the person calling sees it: private for its owner, shared for a participant.
    public var zone: Zone
    /// The invitation to send. Anyone the server lets open it can join.
    public var url: URL?
    /// The owner and everyone invited, owner first.
    public var participants: [ShareParticipant]

    public init(zone: Zone, url: URL?, participants: [ShareParticipant]) {
        self.zone = zone
        self.url = url
        self.participants = participants
    }
}

/// Someone in a share. ≈ `CKShare.Participant`.
public struct ShareParticipant: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable, Codable {
        case owner
        case participant
    }

    public enum Status: String, Sendable, Hashable, Codable {
        /// Invited and hasn't accepted yet.
        case pending
        case accepted
        /// Left, or was removed.
        case removed
    }

    /// The server's name for the person, such as a CloudKit user record name.
    public var id: String
    /// How to show the person, when the server knows.
    public var name: String?
    public var role: Role
    public var status: Status

    public init(id: String, name: String? = nil, role: Role, status: Status) {
        self.id = id
        self.name = name
        self.role = role
        self.status = status
    }
}
