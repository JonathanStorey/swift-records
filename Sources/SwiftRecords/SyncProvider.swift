import Foundation

/// A sync engine: CloudKit's `CKSyncEngine`, or anything shaped like it. The container is its delegate.
///
/// The provider owns scheduling, retries, pushes, change tokens and the account. The container owns the
/// records: it tells the engine what is pending, builds each batch the engine asks for, and applies what
/// the engine reports in `SyncEvent`s. Each requirement names the `CKSyncEngine` API it mirrors, so a
/// CloudKit provider is a thin wrapper. A server without an engine of its own uses `PollingSyncEngine`
/// with a `SyncTransport`.
public protocol SyncProvider: AnyObject, Sendable {
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

    /// ≈ `CKFetchRecordsOperation`. The server's whole copy of each record, and a deletion for one it no
    /// longer has. The container asks only after a partial download it can't apply, so an engine that
    /// always delivers whole records, as `CKSyncEngine` does, never needs it.
    func fetchRecords(_ records: [RecordID]) async throws -> [RecordChangeData]

    /// Moves asset files apart from their records, for a server that stores them separately. `nil`, the
    /// default, means assets need no separate transfer.
    var assetTransfer: (any AssetTransfer)? { get }

    /// Called once as a container opens with this provider, before syncing starts, for a provider that
    /// converts records with the container's help, as `CloudKitSyncProvider` does. Keep it weakly.
    func attach(_ container: RecordContainer)
}

extension SyncProvider {
    public var scopes: Set<Zone.Scope> { [.private] }

    public var assetTransfer: (any AssetTransfer)? { nil }

    public func attach(_ container: RecordContainer) {}

    public func removePending(_ changes: [PendingRecordChange]) {}

    public func addPending(_ changes: [PendingZoneChange]) {}

    public func removePending(_ changes: [PendingZoneChange]) {}

    public func cancelOperations() async {}

    public func fetchRecords(_ records: [RecordID]) async throws -> [RecordChangeData] {
        throw SyncFailure.other("\(Self.self) sends only whole records, so it can't fetch them one by one")
    }
}

/// The engine's delegate. The container implements it, and apps never do. ≈ `CKSyncEngineDelegate`.
public protocol SyncDelegate: AnyObject, Sendable {
    /// ≈ `handleEvent(_:syncEngine:)`. Events for one engine arrive one at a time, in order.
    func handle(_ event: SyncEvent) async

    /// ≈ `nextRecordZoneChangeBatch(_:syncEngine:)`. The next changes to send, or `nil` when nothing in the
    /// context's scope is left to send in this operation.
    func nextBatch(_ context: SendContext) async -> RecordBatch?

    /// ≈ `nextFetchChangesOptions(_:syncEngine:)`. Lets the container put the zones on screen first.
    func nextFetchOptions(_ context: FetchContext) async -> FetchOptions
}

/// Something that happened in the engine. ≈ `CKSyncEngine.Event`, one case each.
public enum SyncEvent: Sendable {
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
public enum PendingRecordChange: Sendable, Hashable, Codable {
    case save(UUID, Zone)
    case delete(UUID, Zone)

    public var id: UUID {
        switch self {
        case .save(let id, _), .delete(let id, _): id
        }
    }

    public var zone: Zone {
        switch self {
        case .save(_, let zone), .delete(_, let zone): zone
        }
    }
}

/// A zone to create or delete on the server. ≈ `CKSyncEngine.PendingDatabaseChange`.
public enum PendingZoneChange: Sendable, Hashable, Codable {
    case save(Zone)
    case delete(Zone)

    public var zone: Zone {
        switch self {
        case .save(let zone), .delete(let zone): zone
        }
    }
}

/// Which records or zones an operation covers. ≈ `CKSyncEngine.SendChangesOptions.Scope`.
public enum ChangeScope: Sendable, Hashable {
    case all
    case zones(Set<Zone>)
    case excludingZones(Set<Zone>)
    case records(Set<UUID>)
    /// Every zone in one database, as each `CKSyncEngine` covers.
    case database(Zone.Scope)

    /// Whether the scope covers a zone at all.
    public func contains(_ zone: Zone) -> Bool {
        switch self {
        case .all, .records: true
        case .database(let scope): zone.scope == scope
        case .zones(let zones): zones.contains(zone)
        case .excludingZones(let zones): !zones.contains(zone)
        }
    }
}

/// ≈ `CKSyncEngine.SendChangesOptions`.
public struct SendOptions: Sendable, Hashable {
    public var scope: ChangeScope

    public init(scope: ChangeScope = .all) {
        self.scope = scope
    }
}

/// ≈ `CKSyncEngine.FetchChangesOptions`.
public struct FetchOptions: Sendable, Hashable {
    public var scope: ChangeScope
    /// Zones to fetch before the others, such as the one on screen.
    public var prioritizedZones: [Zone]

    public init(scope: ChangeScope = .all, prioritizedZones: [Zone] = []) {
        self.scope = scope
        self.prioritizedZones = prioritizedZones
    }
}

/// Why the engine is syncing. ≈ `CKSyncEngine.SyncReason`.
public enum SyncReason: Sendable, Hashable {
    /// The engine decided to, such as after a push or a change.
    case scheduled
    /// Someone called `sendChanges(_:)` or `fetchChanges(_:)`.
    case manual
}

/// ≈ `CKSyncEngine.SendChangesContext`.
public struct SendContext: Sendable, Hashable {
    public let reason: SyncReason
    public let options: SendOptions

    public init(reason: SyncReason, options: SendOptions) {
        self.reason = reason
        self.options = options
    }
}

/// ≈ `CKSyncEngine.FetchChangesContext`.
public struct FetchContext: Sendable, Hashable {
    public let reason: SyncReason
    public let options: FetchOptions

    public init(reason: SyncReason, options: FetchOptions) {
        self.reason = reason
        self.options = options
    }
}

/// Changes to send in one request. ≈ `CKSyncEngine.RecordZoneChangeBatch`.
public struct RecordBatch: Sendable, Hashable {
    public var saves: [RecordChangeData]
    public var deletes: [RecordDeletion]
    /// Whether all of a zone's changes in the batch succeed or fail together. The container sends `false`,
    /// so one conflict fails only its own record.
    public var atomicByZone: Bool

    public init(saves: [RecordChangeData] = [], deletes: [RecordDeletion] = [], atomicByZone: Bool = false) {
        self.saves = saves
        self.deletes = deletes
        self.atomicByZone = atomicByZone
    }

    public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }

    /// Every change in the batch, saves first, as a server that takes one list would want them.
    public var changes: [RecordChangeData] {
        saves + deletes.map { RecordChangeData(id: $0.id, zone: $0.zone, type: $0.type, fields: nil, tag: $0.tag) }
    }
}

/// A record deleted, or to delete. ≈ a `CKRecord.ID` with its record type.
public struct RecordDeletion: Sendable, Hashable, Codable {
    public let id: UUID
    public let zone: Zone
    public let type: String
    /// The tag of the copy the deletion is based on, for a server that checks it. CloudKit doesn't.
    public var tag: Data?

    public init(id: UUID, zone: Zone, type: String, tag: Data? = nil) {
        self.id = id
        self.zone = zone
        self.type = type
        self.tag = tag
    }
}

/// What happened to a batch. ≈ `CKSyncEngine.Event.SentRecordZoneChanges`.
public struct SentRecordChanges: Sendable, Hashable {
    /// The server's copies of the saved records, with their new tags and save times. Their fields may be
    /// left out.
    public var saved: [RecordChangeData]
    public var failed: [FailedSave]
    public var deleted: [RecordDeletion]
    public var failedDeletes: [FailedDelete]

    public init(saved: [RecordChangeData] = [], failed: [FailedSave] = [], deleted: [RecordDeletion] = [], failedDeletes: [FailedDelete] = []) {
        self.saved = saved
        self.failed = failed
        self.deleted = deleted
        self.failedDeletes = failedDeletes
    }
}

/// What happened to zone changes. ≈ `CKSyncEngine.Event.SentDatabaseChanges`.
public struct SentZoneChanges: Sendable, Hashable {
    public var saved: [Zone]
    public var failed: [FailedZoneChange]
    public var deleted: [Zone]

    public init(saved: [Zone] = [], failed: [FailedZoneChange] = [], deleted: [Zone] = []) {
        self.saved = saved
        self.failed = failed
        self.deleted = deleted
    }
}

/// ≈ `CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave`.
public struct FailedSave: Sendable, Hashable {
    public let change: RecordChangeData
    public let failure: SyncFailure

    public init(change: RecordChangeData, failure: SyncFailure) {
        self.change = change
        self.failure = failure
    }
}

public struct FailedDelete: Sendable, Hashable {
    public let deletion: RecordDeletion
    public let failure: SyncFailure

    public init(deletion: RecordDeletion, failure: SyncFailure) {
        self.deletion = deletion
        self.failure = failure
    }
}

public struct FailedZoneChange: Sendable, Hashable {
    public let zone: Zone
    public let failure: SyncFailure

    public init(zone: Zone, failure: SyncFailure) {
        self.zone = zone
        self.failure = failure
    }
}

/// ≈ `CKSyncEngine.Event.AccountChange.ChangeType`, with user IDs as text.
public enum AccountChange: Sendable, Hashable {
    /// Someone signed in, or the engine learned who is signed in for the first time.
    case signIn(user: String)
    /// The person signed out. `nil` when the engine never knew anyone, as on a device that was never signed in.
    case signOut(previousUser: String?)
    case switchAccounts(from: String, to: String)
}

/// A zone the server no longer has. ≈ `CKSyncEngine.Event.FetchedDatabaseChanges.Deletion`.
public struct ZoneDeletion: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// Deleted, such as by the app on another device. Local data goes too.
        case deleted
        /// The person deleted the app's data, such as in Settings. Local data goes too.
        case purged
        /// The server lost the keys to the person's encrypted data. Local data is kept and uploaded again.
        case encryptedDataReset
    }

    public let zone: Zone
    public let reason: Reason

    public init(zone: Zone, reason: Reason) {
        self.zone = zone
        self.reason = reason
    }
}

/// Why a change, or a whole operation, failed. ≈ the `CKError` codes sync has to act on.
public enum SyncFailure: Error, Sendable, Hashable {
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
/// A change can say which fields it touches. On an upload, `changedKeys` and `clearedKeys` name the fields
/// that differ from the copy at `tag`, and `fields` still holds the whole record, so a server that stores
/// whole records ignores them. A CloudKit provider sets only those keys, so an unchanged asset or large field
/// never goes up again. The save still checks `tag`, so conflicts stay whole-record and merge here.
///
/// On a download, a server may send only what changed since the copy at `baseTag`: `changedKeys` names the
/// fields `fields` carries, and `clearedKeys` the ones that became `nil`. The container applies it only to
/// that exact copy, and otherwise asks the provider for the whole record with `fetchRecords(_:)`.
public struct RecordChangeData: Sendable, Hashable {
    public var id: UUID
    public var zone: Zone
    /// The stored type name, such as `"Recipe"`.
    public var type: String
    /// The record's values, or `nil` for a deletion. For a partial download, only the changed fields.
    public var fields: [String: RecordValue]?
    /// The server's data for the copy this change is based on, which only the provider reads: a CloudKit
    /// record's archived system fields, a version number, a hash. `nil` for a copy the server never had,
    /// and always `nil` for a server that doesn't version records.
    public var tag: Data?
    /// When the server saved this copy, if it says. The container stores it as `@Timestamped(.synced)` and
    /// never relies on it.
    public var synced: Date?
    /// The fields set since the copy the change builds on. `nil`: the change is the whole record.
    public var changedKeys: Set<String>?
    /// The fields set to `nil` since the copy the change builds on.
    public var clearedKeys: Set<String>
    /// For a partial download: the tag of the copy it builds on.
    public var baseTag: Data?
    /// The files behind this change's `.asset` values, by asset ID, for a server that keeps files inside
    /// their records, as CloudKit does with `CKAsset`. An upload names every file this device has. A
    /// download names the files that came with it, which the container copies in before the event that
    /// carried them ends. Never encoded.
    public var assetFiles: [String: URL]

    public init(
        id: UUID, zone: Zone, type: String, fields: [String: RecordValue]?, tag: Data? = nil, synced: Date? = nil,
        changedKeys: Set<String>? = nil, clearedKeys: Set<String> = [], baseTag: Data? = nil, assetFiles: [String: URL] = [:]
    ) {
        self.id = id
        self.zone = zone
        self.type = type
        self.fields = fields
        self.tag = tag
        self.synced = synced
        self.changedKeys = changedKeys
        self.clearedKeys = clearedKeys
        self.baseTag = baseTag
        self.assetFiles = assetFiles
    }

    public var isDeletion: Bool { fields == nil }

    /// Whether this is a download of only the fields that changed since `baseTag`, which needs that copy.
    public var isPartial: Bool { !isDeletion && changedKeys != nil && baseTag != nil }

    /// The fields an upload sends: only the changed ones, or every one for a whole-record change.
    public var sentFields: [String: RecordValue]? {
        guard let fields, let changedKeys else { return fields }
        return fields.filter { changedKeys.contains($0.key) }
    }
}

extension RecordChangeData: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, zone, type, fields, tag, synced, changedKeys, clearedKeys, baseTag
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            zone: try container.decode(Zone.self, forKey: .zone),
            type: try container.decode(String.self, forKey: .type),
            fields: try container.decodeIfPresent([String: RecordValue].self, forKey: .fields),
            tag: try container.decodeIfPresent(Data.self, forKey: .tag),
            synced: try container.decodeIfPresent(Date.self, forKey: .synced),
            changedKeys: try container.decodeIfPresent(Set<String>.self, forKey: .changedKeys),
            clearedKeys: try container.decodeIfPresent(Set<String>.self, forKey: .clearedKeys) ?? [],
            baseTag: try container.decodeIfPresent(Data.self, forKey: .baseTag)
        )
    }

    public func encode(to encoder: any Encoder) throws {
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
        try container.encodeIfPresent(baseTag, forKey: .baseTag)
    }
}

/// A record on the server, by its ID, zone and type. ≈ `CKRecord.ID`, with the type for servers that file by it.
public struct RecordID: Sendable, Hashable, Codable {
    public let id: UUID
    public let zone: Zone
    public let type: String

    public init(id: UUID, zone: Zone, type: String) {
        self.id = id
        self.zone = zone
        self.type = type
    }
}

/// A field's value as CloudKit holds it, one case for each kind of `CKRecordValue` a record uses.
public enum RecordValue: Sendable, Hashable {
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
    /// An asset, by its ID. The file crosses separately, through `uploadAssets(_:)` and `downloadAsset(id:zone:into:)`.
    case asset(String)
}

extension RecordValue: Codable {
    // A single key names the kind, so a value written to a file reads plainly: {"string":"Soup"}.
    private enum CodingKeys: String, CodingKey {
        case string, int, double, date, bytes, strings, ints, doubles, dates, reference, action, asset
    }

    public init(from decoder: any Decoder) throws {
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

    public func encode(to encoder: any Encoder) throws {
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

/// An asset file as it crosses to or from a server. Its `id` is the file's unique name, which a record's
/// JSON holds. A file never changes once stored, so an asset can't conflict: a new photo is a new ID.
public struct RecordAssetData: Sendable, Hashable, Codable {
    public let id: String
    public let zone: Zone
    /// The local file to upload.
    public var file: URL

    public init(id: String, zone: Zone, file: URL) {
        self.id = id
        self.zone = zone
        self.file = file
    }
}

/// Moves asset files apart from their records, for a server that stores them separately, such as a
/// folder of files. CloudKit sends a record's files inside it and doesn't use this.
public protocol AssetTransfer: AnyObject, Sendable {
    /// Uploads asset files the server doesn't have yet. Called after records sync, so a record can reach
    /// other devices before its file does.
    func uploadAssets(_ assets: [RecordAssetData]) async throws

    /// Downloads one asset file into `directory` and returns where it landed. Throw when the server doesn't
    /// have it yet, and it's asked for again after the next sync.
    func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL
}
