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

    /// Uploads asset files the server doesn't have yet. Called before the records that use them.
    func uploadAssets(_ assets: [RecordAssetData]) async throws

    /// Downloads one asset file into `directory` and returns where it landed.
    func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL
}

/// One record as it crosses to or from a server: a whole record saved, or a deletion.
///
/// `json` holds every stored property by name, relationships as arrays of IDs, assets as their IDs, and the
/// record's place in its list as `_position` and its last edit time in milliseconds as `_modified`. Treat it
/// as opaque: store it and hand it back. Fields from newer app versions are kept and sent back untouched.
public enum RecordChangeData: Sendable, Hashable, Codable {
    /// A record's latest values. `type` is the stored type name, such as `"Recipe"`. `owner` is the user who
    /// created it, set only in public zones. `synced` is when the server accepted this copy, or `nil` for a
    /// record the server has never accepted.
    case save(id: UUID, zone: Zone, type: String, json: Data, owner: String?, synced: Date?)
    /// A deletion. `synced` is the server's date for the copy that was deleted.
    case delete(id: UUID, zone: Zone, type: String, owner: String?, synced: Date?)

    public var id: UUID {
        switch self {
        case .save(let id, _, _, _, _, _), .delete(let id, _, _, _, _): id
        }
    }

    public var zone: Zone {
        switch self {
        case .save(_, let zone, _, _, _, _), .delete(_, let zone, _, _, _): zone
        }
    }

    public var type: String {
        switch self {
        case .save(_, _, let type, _, _, _), .delete(_, _, let type, _, _): type
        }
    }

    public var owner: String? {
        switch self {
        case .save(_, _, _, _, let owner, _), .delete(_, _, _, let owner, _): owner
        }
    }

    public var synced: Date? {
        switch self {
        case .save(_, _, _, _, _, let synced), .delete(_, _, _, _, let synced): synced
        }
    }

    /// The same change stamped with the server's date, as a server stores it.
    public func syncing(at date: Date) -> RecordChangeData {
        switch self {
        case .save(let id, let zone, let type, let json, let owner, _):
            .save(id: id, zone: zone, type: type, json: json, owner: owner, synced: date)
        case .delete(let id, let zone, let type, let owner, _):
            .delete(id: id, zone: zone, type: type, owner: owner, synced: date)
        }
    }

    public var isDeletion: Bool {
        if case .delete = self { return true }
        return false
    }
}

/// What happened to one uploaded change.
public enum UploadResult: Sendable, Hashable {
    /// Accepted. The server stamped this date.
    case synced(id: UUID, at: Date)
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
