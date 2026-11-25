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
        guard descriptor.includePendingChanges else { return try container.fetch(descriptor, in: zone) }
        var excluded: [String] = [], pending: [Record] = []
        for (id, draft) in drafts where id.zone == zone {
            guard let draft = draft as? Draft<Record> else { continue }
            excluded.append(id.name)
            if let ours = draft.ours, try descriptor.predicate?.evaluate(ours) ?? true { pending.append(ours) }
        }
        // No edit matches, so the database does all of it.
        guard !pending.isEmpty else { return try container.fetch(descriptor, in: zone, excluding: excluded) }
        let offset = max(descriptor.fetchOffset ?? 0, 0), limit = descriptor.fetchLimit.map { max($0, 0) }
        var margin = descriptor
        margin.fetchOffset = nil
        margin.fetchLimit = limit.map { $0 > .max - offset ? .max : offset + $0 }
        let saved = try container.fetch(margin, in: zone, excluding: excluded)
        let merged = descriptor.sortBy.isEmpty ? saved + pending : (saved + pending).sorted(using: descriptor.sortBy)
        return Array(merged.dropFirst(offset).prefix(limit ?? .max))
    }
}
