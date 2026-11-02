import Foundation
import Identification

/// One pair in a many-to-many relationship, such as "this recipe has this tag". There is one type for every
/// many-to-many relationship, and the container registers it itself, so an app never declares or sees it.
///
/// Its ID is hashed from the relationship and both ends, so two devices that link the same pair while
/// offline make the same record, and nothing needs merging. Each end is a pointer with `.deleteSelf`, so
/// deleting either record removes the link, here and on a server. It is stored as `RecordLink`, since a
/// CloudKit record type must start with a letter.
struct _RecordLink: Record {
    var id: UUID
    /// The owning property, such as `"Recipe.tags"`.
    var relation: String
    /// The ID of the record whose array holds the link.
    var from: UUID?
    /// The ID of the record it links to.
    var to: UUID?
    /// When the pair was linked, which orders a relationship without `sort:`.
    var created: Date

    init(relation: String, from: UUID, to: UUID, created: Date = Date()) {
        id = Self.id(relation: relation, from: from, to: to)
        self.relation = relation
        self.from = from
        self.to = to
        self.created = created
    }

    static var schema: RecordSchema<_RecordLink> {
        RecordSchema(table: "RecordLink", fields: [
            .field("id", \.id),
            .field("relation", \.relation),
            .anyReference("from", \.from),
            .anyReference("to", \.to),
            .field("created", \.created),
        ])
    }

    /// The version 5 UUID of a pair, the same on every device.
    static func id(relation: String, from: UUID, to: UUID) -> UUID {
        UUID(name: "\(relation)/\(from.uuidString)/\(to.uuidString)", namespace: namespace)
    }

    /// The namespace link IDs are hashed in.
    private static let namespace = UUID(uuidString: "5C1C7A3E-2D0B-4E4B-9B52-6F3B9A1D2E70")!
}
