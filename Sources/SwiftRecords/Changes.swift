import Foundation

/// A point in a container's change log. Pass it to `changes(since:)` to learn what changed after it.
/// The change log belongs to the sync layer, so it is visible only inside this package.
package struct ChangeToken: Hashable, Comparable, Codable, Sendable {
    package let rawValue: Int64

    package init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Before any change, so `changes(since: .initial)` returns every record's latest change.
    package static let initial = ChangeToken(rawValue: 0)

    package static func < (lhs: ChangeToken, rhs: ChangeToken) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The latest change to one record. The log keeps one entry per record, so saving a record again moves
/// its entry to the end instead of adding another.
package struct RecordChange: Hashable, Sendable {
    package enum Kind: String, Sendable {
        case save
        case delete
    }

    /// The record type's table, such as `"Recipe"`.
    package let recordType: String
    package let id: UUID
    package let kind: Kind
    /// The record's version after this change. A delete takes the next version too.
    package let version: Int
    package let date: Date
    /// Where this change sits in the log. Keep the last one you handled and pass it to `changes(since:)`.
    package let token: ChangeToken
}

/// Bookkeeping kept beside a record that the record itself never sees.
public struct RecordMetadata: Hashable, Sendable {
    /// Goes up by one each time a save changes the record's values or links.
    public let version: Int
    /// When the latest of those changes was saved.
    public let modified: Date?
    /// Sync bookkeeping: the server's `synced` date for the copy this one is based on. Setting it never
    /// changes `version`.
    public let tag: Data?
}
