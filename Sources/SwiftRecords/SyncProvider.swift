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
/// `fields` is keyed by stored property name, and a missing key means `nil`. Each value is a `SyncValue`,
/// which maps onto a `CKRecordValue`. Inverse relationships are never sent, because each device rebuilds
/// them.
public struct SyncRecord: Sendable, Identifiable {
    /// The record's stored type name, such as `"Recipe"`.
    public let type: String
    public let id: UUID
    /// The record's values, or `nil` for a deletion.
    public var fields: [String: SyncValue]?
    /// The server's opaque data for this record, such as a `CKRecord`'s archived system fields. The
    /// container stores it and hands it back with the record's next change.
    public var tag: Data?
    /// When the record was last changed, which settles a conflict under `.latestWins`.
    public var modified: Date?
    /// The record this one belongs to, for a server that groups records, such as a `CKRecord`'s `parent`,
    /// which `CKShare` follows. It is one of the record's references: its first `.deleteSelf` one that is
    /// set, or else its first one that is set. The container sets it when sending and ignores it on receipt.
    public var parent: UUID?
    /// The record's place in its type's stored order, such as the order of a `@Records` list. Lower comes
    /// first, and records that tie are ordered by ID. Store it with the record and hand it back, so
    /// reordering on one device reorders the others.
    public var position: Int64?

    public init(type: String, id: UUID, fields: [String: SyncValue]?, tag: Data? = nil, modified: Date? = nil) {
        self.type = type
        self.id = id
        self.fields = fields
        self.tag = tag
        self.modified = modified
    }

    public var isDeletion: Bool { fields == nil }
}

/// One field value as it crosses to or from a server, with the `CKRecordValue` a CloudKit provider would
/// store it as.
public enum SyncValue: Hashable, Codable, Sendable {
    /// A `String`, or a `UInt64` above `Int64.max`.
    case string(String)
    /// Any integer up to `Int64.max`.
    case int(Int64)
    /// A `Double` or `Float`.
    case double(Double)
    /// A `Bool`. CloudKit stores it as an `Int64` of 0 or 1.
    case bool(Bool)
    /// A `Date`, to the millisecond, as CloudKit keeps it.
    case date(Date)
    /// `Data`, or JSON for any other `Codable` value.
    case data(Data)
    /// A `UUID`. CloudKit stores it as its `uuidString`.
    case uuid(UUID)
    /// A `URL`, or an asset's file, which a CloudKit provider stores as a `CKAsset`.
    case url(URL)
    /// A relationship, in order. Store it as plain strings, such as a CloudKit `[String]` field, not as
    /// references: the children's references decide membership, and the list only keeps their order.
    case ids([UUID])
    /// A child's `@Reference(to:)`: its parent's ID and what happens to it when the parent goes, stored as a
    /// `CKRecord.Reference` with the same action. A `.uuid` or `.string` holding the ID is read the same way.
    case reference(UUID, action: ReferenceAction)
}

extension SyncValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
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
