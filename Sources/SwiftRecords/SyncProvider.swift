import Foundation

/// Moves a zone's records to and from a server, such as CloudKit, a central database or a folder of files.
/// Pass one to `RecordContainer(for:directory:syncProvider:)`, which keeps it for the container's life.
///
/// The provider is transport only, and each call returns what happened. The container decides what is
/// pending, merges conflicts, applies account changes and sets its contexts' `status`. A pass checks the
/// account, uploads pending changes in batches, then downloads until the server has nothing more.
///
/// The unit of sync is a whole record, `RecordChangeData`. The server can give each copy it accepts a `tag`,
/// its own data that the container stores without reading and sends back with the record's next upload,
/// such as a CloudKit record's archived system fields or a version number. That lets the server tell when
/// someone else changed the record first. Throw `SyncError` when a whole call fails.
public protocol SyncProvider: AnyObject, Sendable {
    /// A stable ID for the signed-in user, or `nil` when signed out. Called at the start of every pass.
    func userID() async throws -> String?

    /// Saves and deletes these changes. Returns one result per change, in any order. A change left out
    /// stays pending and goes again with the next pass.
    ///
    /// A server that versions records accepts a save only when its `tag` matches the server's copy, or it
    /// is `nil` and the server has no copy, and otherwise returns the server's copy as a conflict, including
    /// a deletion.
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
    /// downloads from the beginning, and keeps local data even when the account differs. The default
    /// is the provider's type name, so return something more specific when one type can reach several
    /// servers.
    var identifier: String { get }

    /// Whether to sync a zone, asked once as it opens. Return `false` to keep a zone on this device, such as
    /// drafts. `.inMemory` and `.localOnly` never sync and aren't asked. The default syncs every zone.
    func syncs(_ zone: Zone) -> Bool

    /// Whether a zone is one everyone shares, such as a public CloudKit database, asked once as it opens.
    /// The server records who created each of its records and refuses changes from anyone else, signing out
    /// or switching accounts never deletes them, and they download without an account. The default is `false`.
    func isPublic(_ zone: Zone) -> Bool
}

extension SyncProvider {
    public func pushedChanges() -> AsyncStream<[Zone]>? { nil }

    public func syncs(_ zone: Zone) -> Bool { true }

    public func isPublic(_ zone: Zone) -> Bool { false }

    public var identifier: String { String(reflecting: Self.self) }
}

/// One record as it crosses to or from a server, shaped like a `CKRecord`: its values in `fields`, and the
/// server's own data about the copy in `tag`. A deletion has no fields.
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
    /// The server's data for the copy this change is based on, which only the provider reads: a CloudKit
    /// record's archived system fields, a version number, a hash. `nil` for a copy the server never had,
    /// and always `nil` for a server that doesn't version records.
    public var tag: Data?
    /// When the server saved this copy, if it says. The container stores it as `@Timestamped(.synced)` and
    /// never relies on it.
    public var synced: Date?

    public init(id: UUID, zone: Zone, type: String, fields: [String: RecordValue]?, tag: Data? = nil, synced: Date? = nil) {
        self.id = id
        self.zone = zone
        self.type = type
        self.fields = fields
        self.tag = tag
        self.synced = synced
    }

    public var isDeletion: Bool { fields == nil }
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

/// What happened to one uploaded change.
public enum UploadResult: Sendable, Hashable {
    /// Accepted, with the saved copy's new `tag` and, if the server says, when it saved it. The tag goes
    /// back with the record's next upload.
    case saved(id: UUID, tag: Data? = nil, synced: Date? = nil)
    /// The server holds a newer copy, which may be a deletion. The container merges it and uploads again.
    case conflict(RecordChangeData)
    /// Refused for good, such as a record too large or one owned by someone else.
    case rejected(id: UUID)
}

/// A page of a zone's changes from the server.
public struct RecordDownload: Sendable, Hashable {
    public var changes: [RecordChangeData]
    /// Where the next download starts, such as a `CKServerChangeToken` or the newest save time.
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
    /// container keeps its records, uploads them all again and downloads from the beginning.
    case serverReset
}
