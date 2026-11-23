import Foundation
import Versioning

/// One relationship of a `@References(inverse:)` list, stored as a record of its own.
///
/// A relationship joins two sides. Side `i` is the record `references[i]`, which holds the
/// relationship in its property `keyPaths[i]`, as in `"Note.tags"`, at the position
/// `orders[i]` of that list. The sides are sorted by property and then record, so both ends,
/// on any device, build the same relationship, and neither side declares it.
///
/// ```swift
/// var relationship = Relationship(between: ("Note.tags", note), and: ("Tag.notes", tag))
/// relationship[orderIn: note, keyPath: "Note.tags"] = 3
/// relationship.id   // "Note.tags~Tag.notes:E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
/// ```
///
/// A symmetric relationship, like `Person.friends`, has the same property on both sides.
///
/// The container creates and places relationships when it saves a record, and reads them
/// back into its lists when it fetches one, so most code never builds one. Its `references`
/// encode as a reference list, so CloudKit stores them as references you can follow in the
/// Dashboard.
public struct Relationship: Codable, Hashable, Sendable, Identifiable {
    /// The property of each side that holds the relationship, as in `"Note.tags"`.
    public private(set) var keyPaths: [String]
    /// The record of each side, by its record name.
    @Related public private(set) var references: [String]
    /// The relationship's position in each side's list. Orders only need to increase, so
    /// removing a relationship renumbers nothing. `nil` means that side has not placed it
    /// yet, because the other side created it, and it sorts last. Each side writes only its
    /// own order, so two devices reordering opposite sides never conflict.
    public private(set) var orders: [Int?]

    /// A relationship between the record `first.record`, through its property
    /// `first.keyPath`, and the record `second.record`, through `second.keyPath`, not yet
    /// placed in either list. The order of the two sides does not matter.
    public init(between first: (keyPath: String, record: String), and second: (keyPath: String, record: String)) {
        let sides = [first, second].sorted { ($0.keyPath, $0.record) < ($1.keyPath, $1.record) }
        keyPaths = sides.map(\.keyPath)
        _references = Related(sides.map(\.record))
        orders = [nil, nil]
    }

    /// The side whose record is `record` and whose property is `keyPath`, or `nil` when the
    /// relationship has no such side.
    public func side(of record: String, keyPath: String) -> Int? {
        keyPaths.indices.first { references[$0] == record && keyPaths[$0] == keyPath }
    }

    /// The position of the relationship in the list `keyPath` of `record`. Setting it on a
    /// side the relationship lacks does nothing.
    public subscript(orderIn record: String, keyPath keyPath: String) -> Int? {
        get { side(of: record, keyPath: keyPath).flatMap { orders[$0] } }
        set {
            if let side = side(of: record, keyPath: keyPath) { orders[side] = newValue }
        }
    }

    /// The record on the other side from the side `record` holds in `keyPath`.
    public func target(from record: String, keyPath: String) -> String {
        side(of: record, keyPath: keyPath) == 0 ? references[1] : references[0]
    }

    /// The relationship's record name: both properties, then a stable hash of the
    /// properties and both records, as in `"Note.tags~Tag.notes:E621E1F8-…"`. The same
    /// relationship always maps to the same record, so it is derived rather than stored,
    /// and removing one needs no lookup. No other record name contains `~`, so it never
    /// collides with one.
    public var id: String {
        keyPaths.joined(separator: "~") + ":" + UUID(stableHashOf: (keyPaths + references).joined(separator: "|")).uuidString
    }
}

extension Relationship {
    /// Whether the relationship has exactly two sides, as every one built here does. One
    /// decoded from damaged data might not, and the container skips it.
    var isWellFormed: Bool {
        keyPaths.count == 2 && references.count == 2 && orders.count == 2
    }
}

extension Relationship: Mergeable {
    /// Each side's order merged on its own, so two devices that each reorder one side keep
    /// both. Relationships between other sides conflict.
    public func merging(with theirs: Relationship, from base: Relationship) throws(MergeConflict) -> Relationship {
        guard keyPaths == theirs.keyPaths, references == theirs.references, base.orders.count == orders.count, theirs.orders.count == orders.count else { throw MergeConflict() }
        var merged = self
        for side in orders.indices where orders[side] == base.orders[side] {
            merged.orders[side] = theirs.orders[side]
        }
        return merged
    }

    /// Without a base, equal relationships merge, and any others conflict.
    public func merging(with theirs: Relationship) throws(MergeConflict) -> Relationship {
        guard self == theirs else { throw MergeConflict() }
        return self
    }
}
