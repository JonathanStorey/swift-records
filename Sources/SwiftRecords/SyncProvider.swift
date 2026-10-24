import Foundation

/// Moves a zone's records to and from a server, such as CloudKit, a central database or a folder of files.
/// Pass one to `RecordContainer(for:directory:syncProvider:)`, which keeps it for the container's life.
///
/// The provider is transport only, and each call returns what happened. The container decides what is
/// pending, merges conflicts, applies account changes and sets its contexts' `status`. A pass checks the
/// account, uploads pending changes in batches, then downloads until the server has nothing more.
///
/// The unit of sync is a whole record, `RecordChangeData`. The server stamps each accepted change with a
/// strictly later `synced` date. An upload carries the `synced` date of the copy it was edited from, so the
/// server can tell when someone else changed the record first. Throw `SyncError` when a whole call fails.
public protocol SyncProvider: AnyObject, Sendable {
    /// A stable ID for the signed-in user, or `nil` when signed out. Called at the start of every pass.
    func userID() async throws -> String?

    /// Saves and deletes these changes. Returns one result per change, in any order. A change left out
    /// stays pending and goes again with the next pass.
    ///
    /// Accept a save only when its `synced` date matches the server's copy, or it is `nil` and the server
    /// has no copy. Otherwise return the server's copy as a conflict, including a deletion.
    func uploadRecordChanges(_ changes: [RecordChangeData]) async throws -> [UploadResult]

    /// Returns the zone's changes after `cursor`, oldest first, with each record's latest change only.
    /// `nil` starts from the beginning. The container stores the new cursor together with the changes.
    func downloadRecordChanges(in zone: Zone, after cursor: Data?) async throws -> RecordDownload

    /// Uploads asset files the server doesn't have yet. Called in the background after records sync, so a
    /// record can reach the server, and other devices, before its file does.
    func uploadAssets(_ assets: [RecordAssetData]) async throws

    /// Downloads one asset file into `directory` and returns where it landed. Throw when the server doesn't
    /// have it yet, and it's asked for again after the next pass.
    func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL

    /// Zones the server says have changed, such as from a push notification, so the container downloads
    /// them without waiting for a refresh. Called once for each zone that syncs: return a new stream each
    /// time, and send every push to all of them. `nil`, the default, means the provider can't tell.
    func pushedChanges() -> AsyncStream<[Zone]>?

    /// Names the server this provider talks to, such as its URL. When it differs from the one a zone last
    /// synced with, the container treats the new server as empty: it uploads every local record and
    /// downloads from the beginning, and keeps local data whatever the account policies say. The default
    /// is the provider's type name, so return something more specific when one type can reach several
    /// servers.
    var identifier: String { get }
}

extension SyncProvider {
    public func pushedChanges() -> AsyncStream<[Zone]>? { nil }

    public var identifier: String { String(reflecting: Self.self) }
}

/// One record as it crosses to or from a server, shaped like a `CKRecord`: its values in `fields`, and the
/// server's bookkeeping beside them in `metadata`. A deletion has no fields.
///
/// `fields` holds every stored property by name, as CloudKit stores it: a relationship is its records' IDs
/// in order as `.strings`, a child's `@Reference(to:)` is a `.reference`, and an asset is its ID. Treat the
/// fields as opaque where you can: store them and hand them back. Fields from newer app versions are kept
/// and sent back untouched.
public struct RecordChangeData: Sendable, Hashable, Codable {
    public var id: UUID
    public var zone: Zone
    /// The stored type name, such as `"Recipe"`.
    public var type: String
    /// The record's values, or `nil` for a deletion.
    public var fields: [String: RecordValue]?
    public var metadata: SyncMetadata

    public init(id: UUID, zone: Zone, type: String, fields: [String: RecordValue]?, metadata: SyncMetadata = SyncMetadata()) {
        self.id = id
        self.zone = zone
        self.type = type
        self.fields = fields
        self.metadata = metadata
    }

    public var isDeletion: Bool { fields == nil }

    /// When the server accepted this copy. The same as `metadata.synced`.
    public var synced: Date? { metadata.synced }

    /// The same change stamped with the server's date, as a server stores it.
    public func syncing(at date: Date) -> RecordChangeData {
        var change = self
        change.metadata.synced = date
        return change
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
            let action = try container.decodeIfPresent(ReferenceAction.self, forKey: .action) ?? .none
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
            if action != .none { try container.encode(action, forKey: .action) }
        case .asset(let id): try container.encode(id, forKey: .asset)
        }
    }
}

/// What the server keeps about a record beside its values, like a `CKRecord`'s system fields.
public struct SyncMetadata: Sendable, Hashable, Codable {
    /// When the server accepted this copy, or `nil` for a record it has never accepted. The server stamps
    /// each accepted change with a strictly later date.
    public var synced: Date?
    /// The user who created the record, set only in public zones.
    public var owner: String?
    /// The provider's own bookkeeping for the copy, such as a `CKRecord`'s archived system fields. The
    /// container stores it with the record and hands it back, untouched, with the record's next upload.
    public var systemFields: Data?

    public init(synced: Date? = nil, owner: String? = nil, systemFields: Data? = nil) {
        self.synced = synced
        self.owner = owner
        self.systemFields = systemFields
    }
}

/// What happened to one uploaded change.
public enum UploadResult: Sendable, Hashable {
    /// Accepted. The server stamped this date. `systemFields` is the provider's new bookkeeping for the
    /// saved copy, such as a `CKRecord`'s archived system fields, which goes back with the next upload.
    case synced(id: UUID, at: Date, systemFields: Data? = nil)
    /// The server holds a newer copy, which may be a deletion. The container merges it and uploads again.
    case conflict(RecordChangeData)
    /// Refused for good, such as a record too large or one owned by someone else.
    case rejected(id: UUID)
}

/// A page of a zone's changes from the server.
public struct RecordDownload: Sendable, Hashable {
    public var changes: [RecordChangeData]
    /// Where the next download starts. A server that stamps `synced` dates can simply encode the newest one.
    public var cursor: Data?
    /// Whether more changes are waiting after this page.
    public var hasMore: Bool

    public init(changes: [RecordChangeData], cursor: Data?, hasMore: Bool = false) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
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

/// Why a whole provider call failed. Any other error counts as `offline`.
public enum SyncError: Error, Sendable, Hashable {
    /// The network or server can't be reached. Changes stay pending, and the context shows `.offline`.
    case offline
    /// The account is out of storage.
    case storageFull
    /// The server's copy of the zone is gone, for example because the person deleted it in Settings. The
    /// container applies its `onServerReset` policy and downloads from the beginning.
    case serverReset
}

/// How a conflict between an unsent local edit and the server's copy of a record is settled.
public indirect enum MergePolicy: Sendable, Hashable {
    /// The server's copy replaces the local edit.
    case serverWins
    /// The local edit replaces the server's copy.
    case localWins
    /// The copy changed most recently wins.
    case latestWins
    /// Each property, and each item of a relationship, keeps the change whichever side made it. Only a
    /// property both sides changed to different values falls to `otherwise`.
    case mergeProperties(otherwise: MergePolicy)

    /// Properties merge, and true clashes go to the latest edit.
    public static let `default` = MergePolicy.mergeProperties(otherwise: .latestWins)
}

/// What happens to the records on this device when its account signs out, switches or loses its server data.
public enum AccountPolicy: Sendable, Hashable {
    /// Keep them, and upload them when an account is next available.
    case keepLocalData
    /// Delete them from this device. The server keeps its copy.
    case deleteLocalData
}
