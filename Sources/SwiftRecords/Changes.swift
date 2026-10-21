import Foundation

/// A point in a container's change log. Pass it to `RecordContainer.changes(since:)` to learn what
/// changed after it.
public struct ChangeToken: Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Before any change, so `changes(since: .initial)` returns every record's latest change.
    public static let initial = ChangeToken(rawValue: 0)

    public static func < (lhs: ChangeToken, rhs: ChangeToken) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The latest change to one record. The log keeps one entry per record, so saving a record again moves
/// its entry to the end instead of adding another.
public struct RecordChange: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case save
        case delete
    }

    /// The record type's table, such as `"Recipe"`.
    public let recordType: String
    public let id: UUID
    public let kind: Kind
    /// The record's version after this change. A delete takes the next version too.
    public let version: Int
    public let date: Date
    /// Where this change sits in the log. Keep the last one you handled and pass it to `changes(since:)`.
    public let token: ChangeToken
}

/// Bookkeeping kept beside a record that the record itself never sees.
public struct RecordMetadata: Hashable, Sendable {
    /// Goes up by one each time a save changes the record's values, links or order.
    public let version: Int
    /// When the latest of those changes was saved.
    public let modified: Date?
    /// Opaque data owned by a sync layer, such as a `CKRecord`'s archived system fields. Setting it never
    /// changes `version`.
    public let tag: Data?
}
