import Foundation
import Versioning

/// One link of a ``References`` property, stored as a record of its own.
///
/// It is an ordinary model, `Identifiable` by a `UUID` and `Codable` by
/// synthesis, except that its ``id`` is derived rather than stored. Its
/// `references` encode as a reference list, so CloudKit stores them as
/// references you can follow in the Dashboard.
///
/// The container creates a `@References` list's links with
/// ``init(keyPath:from:to:symmetric:)`` and places them with
/// ``subscript(orderIn:)`` when it saves a record, and reads them back into
/// the list when it fetches one.
///
/// A link is named by the declaring side alone. Linking a note to a tag
/// through `Note.tags` gives `keyPath == "Note.tags"` and
/// `references == [note.id, tag.id]`, declaring record first. The target
/// never needs to declare an inverse, and an inverse it declares later names
/// the same key path, so both sides build the same link. Adding or removing
/// an inverse never changes a stored link.
///
/// One query, `keyPath == "Note.tags" AND references CONTAINS` a record,
/// finds every link to it from either side.
public struct Relationship: Codable, Hashable, Sendable, Identifiable, Mergeable {
    /// The declaring type and property, as in `"Note.tags"`.
    public private(set) var keyPath: String
    /// The declaring record's name, then the target's, as ``RecordID/name`` gives them.
    @Related public private(set) var references: [String]
    /// The link's position in the list of `references[0]`, the declaring
    /// record. Orders only need to increase, so deleting a link never
    /// renumbers the others. `nil` means the link has not been placed yet,
    /// because the other side created it, and it sorts last.
    public var order: Int?
    /// The link's position in the list of `references[1]`, for an inverse
    /// declared on the target's side. Each side writes only its own
    /// order, so the two sides never conflict over a field.
    public var inverseOrder: Int?
    /// The target's property that reads the link back, as in `"Tag.notes"`, or `nil`
    /// when the target declares no inverse. The container fills the inverse's list from it.
    public var inverseKeyPath: String?

    /// A link from `source` to `target` through `keyPath`, not yet placed
    /// in either list.
    ///
    /// A symmetric relationship is its own inverse, like `Person.friends`.
    /// It has no declaring side, so its ids are sorted and the link is the
    /// same whichever record creates it.
    public init(keyPath: String, from source: String, to target: String, symmetric: Bool = false) {
        self.keyPath = keyPath
        let swapped = symmetric && target < source
        _references = Related(swapped ? [target, source] : [source, target])
    }

    /// The link's position in the list of `record`, one of its two ends:
    /// ``order`` for `references[0]` and ``inverseOrder`` for
    /// `references[1]`. Use it to place a link without knowing which side
    /// declared it, as a symmetric link requires.
    ///
    /// ```swift
    /// var link = Relationship(keyPath: "Note.tags", from: note, to: tag)
    /// link[orderIn: note] = 3
    /// ```
    public subscript(orderIn record: String) -> Int? {
        get { references[0] == record ? order : inverseOrder }
        set {
            if references[0] == record { order = newValue } else { inverseOrder = newValue }
        }
    }

    /// The link's record name: a stable hash of the key path and both ids,
    /// so the same link always maps to the same record, and moving it
    /// updates that record in place. It is derived, so it is never stored,
    /// never disagrees with the link, and lets a removal delete the link
    /// without fetching it.
    public var id: UUID {
        UUID(stableHashOf: ([keyPath] + references).joined(separator: "|"))
    }

    /// The id at the other end of the link from `source`.
    public func target(from source: String) -> String {
        references[0] == source ? references[1] : references[0]
    }
}
