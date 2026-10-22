import Foundation

/// A context for work off the main actor, handed to you by `RecordContainer.performBackgroundTask(in:_:)`.
///
/// Unlike the main context it has no pending changes, autosave or observation. Each save or delete
/// commits right away, and `transaction(_:)` groups several into one commit. The main context refreshes
/// after each commit, so views show the results.
public struct BackgroundContext {
    let storage: ZoneStorage

    /// The zone this context reads and writes.
    public var zone: String? { storage.zone }

    init(storage: ZoneStorage) {
        self.storage = storage
    }

    /// Runs `body` atomically: every save and delete inside it commits together, or none do.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try storage.transaction(body)
    }

    // MARK: Changes

    /// Inserts the record, or updates it if one with the same ID exists.
    public func save<R: Record>(_ record: R) throws {
        try storage.save(record)
    }

    public func save<R: Record>(_ records: [R]) throws {
        try storage.save(records)
    }

    public func delete<R: Record>(_ record: R) throws {
        try storage.delete(record)
    }

    public func delete<R: Record>(_ type: R.Type, id: R.ID) throws {
        try storage.delete(type, id: id)
    }

    /// Deletes every record that matches the predicate, applying each one's delete rules. Without a
    /// predicate it deletes every record of the type.
    public func delete<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws {
        try storage.delete(type, where: predicate)
    }

    // MARK: Fetching

    /// Fetches records matching a predicate in their stored order.
    public func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil) throws -> [R] {
        try storage.fetch(type, where: predicate)
    }

    /// Fetches one page of records. See `RecordContext.fetch(_:where:limit:offset:)`.
    public func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        limit: Int,
        offset: Int = 0
    ) throws -> RecordSlice<R> {
        try storage.fetch(type, where: predicate, limit: limit, offset: offset)
    }

    public func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try storage.fetch(type, id: id)
    }

    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try storage.fetch(type, ids: ids)
    }

    /// Fetches records by ID in their stored order, such as an inverse relationship's owners.
    public func fetch<R: Record>(_ type: R.Type, ids: Set<UUID>) throws -> [R] {
        try storage.fetch(type, ids: ids)
    }

    public func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try storage.count(type, where: predicate)
    }
}

@available(*, unavailable)
extension BackgroundContext: Sendable {}
