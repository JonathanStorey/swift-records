import Foundation

/// A context for work off the main actor, handed to you by `RecordContainer.performBackgroundTask(_:)`.
///
/// Unlike the main context it has no pending changes, autosave or observation. Each save or delete
/// commits right away, and `transaction(_:)` groups several into one commit. The main context refreshes
/// after each commit, so views show the results.
public struct BackgroundContext {
    let container: RecordContainer

    init(container: RecordContainer) {
        self.container = container
    }

    /// Runs `body` atomically: every save and delete inside it commits together, or none do.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try container.transaction(body)
    }

    // MARK: Changes

    /// Inserts the record, or updates it if one with the same ID exists.
    public func save<R: Record>(_ record: R) throws {
        try container.save(record)
    }

    public func save<R: Record>(_ records: [R]) throws {
        try container.save(records)
    }

    public func delete<R: Record>(_ record: R) throws {
        try container.delete(record)
    }

    public func delete<R: Record>(_ type: R.Type, id: R.ID) throws {
        try container.delete(type, id: id)
    }

    // MARK: Fetching

    /// Fetches records matching a predicate in their stored order.
    public func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil) throws -> [R] {
        try container.fetch(type, where: predicate)
    }

    /// Fetches one page of records. See `RecordsContext.fetch(_:where:limit:offset:)`.
    public func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        limit: Int,
        offset: Int = 0
    ) throws -> RecordSlice<R> {
        try container.fetch(type, where: predicate, limit: limit, offset: offset)
    }

    public func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try container.fetch(type, id: id)
    }

    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try container.fetch(type, ids: ids)
    }

    public func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try container.count(type, where: predicate)
    }
}

@available(*, unavailable)
extension BackgroundContext: Sendable {}
