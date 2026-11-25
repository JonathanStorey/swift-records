import Foundation

/// Which records of one type to fetch, and in what order, as `FetchDescriptor` describes
/// them in SwiftData.
///
/// ```swift
/// var recent = RecordDescriptor<Note>(predicate: #Predicate { !$0.isArchived }, sortBy: [SortDescriptor(\.modified, order: .reverse)])
/// recent.fetchLimit = 20
/// ```
///
/// When the predicate and every sort translate to SQL, SQLite sorts, skips `fetchOffset` and
/// stops at `fetchLimit` itself, so only the records returned are read. A `String` sorts
/// in SQL by its comparator, `.localizedStandard` by default on Apple platforms, through a
/// collation that calls Foundation's own comparison. A sort SQL cannot match, such as an
/// enum's own `<`, still returns the same records, sorted in Swift after every match is read.
public struct RecordDescriptor<Record: Codable> {
    /// Which records to include, or `nil` for every one.
    public var predicate: Predicate<Record>?
    /// The order, first descriptor first. Records that tie keep no particular order.
    public var sortBy: [SortDescriptor<Record>]
    /// The most records to return, or `nil` for no limit.
    public var fetchLimit: Int?
    /// How many records to skip, in order, before the first one returned.
    public var fetchOffset: Int?
    /// Whether a context includes its unsaved inserts, edits and deletes. The container has
    /// none, so it ignores this.
    public var includePendingChanges = true

    public init(predicate: Predicate<Record>? = nil, sortBy: [SortDescriptor<Record>] = []) {
        self.predicate = predicate
        self.sortBy = sortBy
    }
}

extension RecordDescriptor {
    /// `fetchOffset`, with `nil` and below zero as zero.
    var offset: Int { max(fetchOffset ?? 0, 0) }
    /// `fetchLimit`, with below zero as zero.
    var limit: Int? { fetchLimit.map { max($0, 0) } }
    /// How many of `total` matching records the offset and limit leave.
    func count(ofPageIn total: Int) -> Int { min(max(total - offset, 0), limit ?? .max) }
}
