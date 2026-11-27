import Foundation

extension RecordContext {
    /// The records `descriptor` describes in ``zone``, as `ModelContext.fetch(_:)` returns
    /// them in SwiftData.
    ///
    /// With `includePendingChanges`, the default, the records being edited are included as
    /// edited, and deleted ones are left out, before the offset and limit apply. The saved
    /// rows being edited are left out of the database's part, which stops at
    /// `fetchOffset + fetchLimit` rows. That margin is exact: the edits that match are sorted
    /// in with it, and only then is the page taken, so no edit pushes a saved record off the
    /// page or pulls one in that should not be there.
    ///
    /// ```swift
    /// var page = RecordDescriptor<Note>(sortBy: [SortDescriptor(\.modified, order: .reverse)])
    /// page.fetchLimit = 20
    /// let notes = try context.fetch(page)
    /// ```
    public func fetch<Record: Codable>(_ descriptor: RecordDescriptor<Record>) throws -> [Record] {
        try fetch(descriptor, in: zone)
    }

    /// The records `descriptor` describes in `zone`, with this context's edits in that zone,
    /// as ``fetch(_:)`` returns them in ``zone``.
    ///
    /// ```swift
    /// let shared = try context.fetch(RecordDescriptor<Note>(), in: "Shared")
    /// ```
    public func fetch<Record: Codable>(_ descriptor: RecordDescriptor<Record>, in zone: Zone) throws -> [Record] {
        _ = revision
        guard descriptor.includePendingChanges else { return try container.fetch(descriptor, in: zone) }
        let (excluded, pending) = try pendingChanges(descriptor, in: zone)
        // No edit matches, so the database does all of it.
        guard !pending.isEmpty else { return try container.fetch(descriptor, in: zone, excluding: excluded) }
        let offset = descriptor.offset, limit = descriptor.limit
        var margin = descriptor
        margin.fetchOffset = nil
        margin.fetchLimit = limit.map { $0 > .max - offset ? .max : offset + $0 }
        let saved = try container.fetch(margin, in: zone, excluding: excluded)
        let merged = descriptor.sortBy.isEmpty ? saved + pending : (saved + pending).sorted(using: descriptor.sortBy)
        return Array(merged.dropFirst(offset).prefix(limit ?? .max))
    }

    /// How many records ``fetch(_:)`` would return, as `ModelContext.fetchCount(_:)` counts
    /// them, without reading the saved ones when the predicate translates to SQL.
    ///
    /// ```swift
    /// let unread = try context.fetchCount(RecordDescriptor<Note>(predicate: #Predicate { !$0.isRead }))
    /// ```
    public func fetchCount<Record: Codable>(_ descriptor: RecordDescriptor<Record>) throws -> Int {
        try fetchCount(descriptor, in: zone)
    }

    /// How many records ``fetch(_:in:)`` would return from `zone`.
    ///
    /// ```swift
    /// let shared = try context.fetchCount(RecordDescriptor<Note>(), in: "Shared")
    /// ```
    public func fetchCount<Record: Codable>(_ descriptor: RecordDescriptor<Record>, in zone: Zone) throws -> Int {
        _ = revision
        guard descriptor.includePendingChanges else { return try container.fetchCount(descriptor, in: zone) }
        let (excluded, pending) = try pendingChanges(descriptor, in: zone)
        var all = descriptor
        all.fetchOffset = nil
        all.fetchLimit = nil
        return descriptor.count(ofPageIn: try container.fetchCount(all, in: zone, excluding: excluded) + pending.count)
    }

    /// The records `references` lists, in its order, as ``record(_:id:)`` returns each one:
    /// its open edit, or else its saved value. A target that is deleted, or has not arrived
    /// yet, is left out.
    ///
    /// A field list and a relationship list read the same way, since a fetched record's
    /// relationship lists come back filled. Every target lives in its holder's zone, which
    /// for a record read through this context is ``zone``.
    ///
    /// ```swift
    /// let tags = context.fetch(note.$tags)
    /// ```
    public func fetch<Record: Codable & Identifiable>(_ references: References<Record>) -> [Record] {
        references.wrappedValue.compactMap { record(Record.self, id: $0) }
    }

    /// The names of the rows of `Record` open in `zone`, which the database's part leaves
    /// out, and the open edits that `descriptor`'s predicate matches.
    private func pendingChanges<Record: Codable>(_ descriptor: RecordDescriptor<Record>, in zone: Zone) throws -> (excluded: [String], pending: [Record]) {
        var excluded: [String] = [], pending: [Record] = []
        for (id, draft) in drafts where id.zone == zone {
            guard let draft = draft as? Draft<Record> else { continue }
            excluded.append(id.name)
            if let ours = draft.ours, try descriptor.predicate?.evaluate(ours) ?? true { pending.append(ours) }
        }
        return (excluded, pending)
    }
}
