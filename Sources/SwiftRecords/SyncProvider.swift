import Foundation

/// Keeps a zone's records in step with a server, such as CloudKit. Pass one to
/// `RecordContainer(for:zone:directory:syncProvider:)`, which keeps it for the container's life.
///
/// The provider is transport only. The container decides what is pending, merges conflicts, applies
/// account changes and sets its contexts' `status`. The provider never calls the container: it answers
/// every call through the `report` function it receives in `open(state:report:)`.
public protocol SyncProvider: AnyObject, Sendable {
    /// Called once when the container opens, with the state the provider last reported, or `nil` the
    /// first time. Report the current account with `.accountChanged(_:)`.
    func open(state: Data?, report: @escaping @Sendable (SyncEvent) async -> Void) async

    /// Uploads these records and deletions. Report each outcome as `.sent`, `.notSent`, or `.received`
    /// with the server's copy when the server holds a newer one.
    func send(_ records: [SyncRecord]) async

    /// Fetches the server's changes and returns once they have been reported as `.received`.
    func fetch() async
}

/// One record as it crosses to or from a server.
///
/// `fields` is keyed by stored property name and holds only standard types: `String`, `Int64`, `Double`,
/// `Bool`, `Date`, `UUID` and `Data`, with `Data` holding JSON for any other `Codable` value. A missing key
/// means `nil`.
///
/// - A child's `@Reference(to:)` is a `SyncReference`, which a CloudKit provider stores as a
///   `CKRecord.Reference` with the same action.
/// - A relationship is a `[UUID]` in order, and a to-one relationship an array of zero or one. Store it as
///   plain strings, such as a CloudKit `[String]` field, not as references: the children's references
///   decide membership, and the list only keeps their order.
/// - An asset is a file `URL`, such as a `CKAsset`'s.
/// - Inverse relationships are never sent, because each device rebuilds them.
public struct SyncRecord: Sendable, Identifiable {
    /// The record's stored type name, such as `"Recipe"`.
    public let type: String
    public let id: UUID
    /// The record's values, or `nil` for a deletion.
    public var fields: [String: any Sendable]?
    /// The server's opaque data for this record, such as a `CKRecord`'s archived system fields. The
    /// container stores it and hands it back with the record's next change.
    public var tag: Data?
    /// When the record was last changed, which settles a conflict under `.latestWins`.
    public var modified: Date?
    /// The record this one belongs to, for a server that groups records, such as a `CKRecord`'s `parent`,
    /// which `CKShare` follows. It is one of the record's references: its first `.deleteSelf` one that is
    /// set, or else its first one that is set. The container sets it when sending and ignores it on receipt.
    public var parent: UUID?

    public init(type: String, id: UUID, fields: [String: any Sendable]?, tag: Data? = nil, modified: Date? = nil) {
        self.type = type
        self.id = id
        self.fields = fields
        self.tag = tag
        self.modified = modified
    }

    public var isDeletion: Bool { fields == nil }
}

/// A child's `@Reference(to:)` as it crosses to or from a server: the parent's ID and what happens to the
/// child when the parent goes. A provider may also hand back a plain `UUID` or its string.
public struct SyncReference: Sendable, Hashable {
    public let id: UUID
    public let action: ReferenceAction

    public init(id: UUID, action: ReferenceAction) {
        self.id = id
        self.action = action
    }
}

/// What a provider reports. The container turns these into stored changes and its contexts' `status`.
public enum SyncEvent: Sendable {
    /// Changes from the server, applied together with the provider's new state in one transaction.
    case received([SyncRecord], state: Data?)
    /// Records the server accepted, each with its new tag.
    case sent([SyncRecord], state: Data?)
    /// Records that weren't sent. They stay pending and go again with the next save or refresh.
    case notSent([SyncRecord], because: Reason)
    /// A stable identifier for the signed-in account, or `nil` once signed out.
    case accountChanged(String?)
    /// The server's copy of the zone is gone, for example because the person deleted it in Settings.
    case serverReset
    /// The provider's own state, handed back to `open(state:report:)` next launch.
    case stateChanged(Data)

    public enum Reason: Sendable {
        /// The network or server can't be reached. The context shows `.offline`.
        case unreachable
        /// The account is out of storage.
        case storageFull
        /// The server refused the record for good.
        case rejected
    }
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
