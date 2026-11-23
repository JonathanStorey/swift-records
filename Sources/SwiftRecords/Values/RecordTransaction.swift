import Foundation

/// The changes one transaction committed to a ``RecordContainer``, as
/// ``RecordContainer/transactions()`` reports them.
///
/// ```swift
/// for await transaction in container.transactions() where transaction.author == "sync" {
///     showEditedElsewhere(transaction.changes.map(\.id))
/// }
/// ```
public struct RecordTransaction: Identifiable, Hashable, Sendable {
    /// The transaction's place among those this container committed, counting from 1, so a
    /// later transaction has a larger id.
    public let id: Int64
    /// Who made the changes: `"sync"` for the sync engine, or the name the writer gave, or
    /// `nil` when it gave none.
    public let author: String?
    /// When the changes were made.
    public let timestamp: Date
    /// Each record the transaction changed, in the order it changed them.
    public let changes: [Change]

    /// One record's change.
    public enum Change: Hashable, Sendable {
        case inserted(RecordID<Any>, type: String)
        case updated(RecordID<Any>, type: String)
        case deleted(RecordID<Any>, type: String)
    }
}

extension RecordTransaction.Change {
    /// The id of the record that changed.
    public var id: RecordID<Any> {
        switch self {
        case .inserted(let id, _), .updated(let id, _), .deleted(let id, _): id
        }
    }
}
