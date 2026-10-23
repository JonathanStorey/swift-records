import Foundation

/// A context for work off the main actor, handed to you by `RecordContainer.performBackgroundTask(in:_:)`.
///
/// Unlike the main context it has no pending changes, autosave or observation. Each insert or delete
/// commits right away, and `transaction(_:)` groups several into one commit. The main context refreshes
/// after each commit, so views show the results.
public struct BackgroundContext {
    let storage: ZoneStorage

    /// The zone this context reads and writes.
    public var zone: Zone { storage.zone }

    init(storage: ZoneStorage) {
        self.storage = storage
    }

    /// Runs `body` atomically: every insert and delete inside it commits together, or none do.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try storage.transaction(body)
    }

    // MARK: Changes

    /// Adds the record, or replaces the one with the same ID. A new record joins the end of its type's
    /// stored order.
    public func insert<R: Record>(_ record: R) throws {
        try storage.save(record)
    }

    /// Adds or replaces each record in one commit.
    public func insert<R: Record>(_ records: [R]) throws {
        try storage.save(records)
    }

    public func delete<R: Record>(_ record: R) throws {
        try storage.delete(record)
    }

    /// Deletes every record of the type that matches the predicate, applying each one's delete rules.
    /// Without a predicate it deletes every record of the type.
    public func delete<R: Record>(record type: R.Type, where predicate: Predicate<R>? = nil) throws {
        try storage.delete(type, where: predicate)
    }

    // MARK: Fetching

    /// Fetches the records the descriptor matches in their stored order.
    public func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
        try storage.fetch(descriptor)
    }

    /// Fetches every record of the type in its stored order.
    public func fetch<R: Record>(_ type: R.Type) throws -> [R] {
        try storage.fetch(RecordDescriptor<R>())
    }

    public func fetchCount<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> Int {
        try storage.fetchCount(descriptor)
    }

    public func fetchIdentifiers<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [UUID] {
        try storage.fetchIdentifiers(descriptor)
    }

    /// The record with this ID, or `nil` if there's none.
    public func record<R: Record>(_ type: R.Type = R.self, for id: R.ID) throws -> R? {
        try storage.fetch(type, id: id)
    }
}

@available(*, unavailable)
extension BackgroundContext: Sendable {}
