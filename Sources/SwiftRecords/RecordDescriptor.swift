import Foundation

/// Which records to fetch and how many, like SwiftData's `FetchDescriptor`. Records come back in their
/// stored order. For another order, sort a copy.
///
/// ```swift
/// let page = try context.fetch(RecordDescriptor<Recipe>(predicate: #Predicate { $0.servings > 2 }, fetchLimit: 20))
/// ```
public struct RecordDescriptor<R: Record>: Sendable {
    /// Which records match. `nil` matches every record of the type. Simple predicates on a record's own
    /// properties run as SQL, and anything else is evaluated in memory.
    public var predicate: Predicate<R>?
    /// The most records to return, or `nil` for all of them.
    public var fetchLimit: Int?
    /// How many matching records to skip first.
    public var fetchOffset: Int?

    public init(predicate: Predicate<R>? = nil, fetchLimit: Int? = nil, fetchOffset: Int? = nil) {
        precondition((fetchLimit ?? 0) >= 0 && (fetchOffset ?? 0) >= 0, "fetchLimit and fetchOffset must not be negative")
        self.predicate = predicate
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
    }

    /// The page to read, or `nil` for every match.
    var page: (limit: Int, offset: Int)? {
        guard fetchLimit != nil || fetchOffset != nil else { return nil }
        return (fetchLimit ?? Int(Int64.max), fetchOffset ?? 0)
    }
}

extension ZoneStorage {
    func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
        guard let page = descriptor.page else { return try fetch(R.self, where: descriptor.predicate) }
        return Array(try fetch(R.self, where: descriptor.predicate, limit: page.limit, offset: page.offset))
    }

    func fetchCount<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> Int {
        let count = try count(R.self, where: descriptor.predicate)
        guard let page = descriptor.page else { return count }
        return min(max(count - page.offset, 0), page.limit)
    }

    func fetchIdentifiers<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [UUID] {
        try store.ids(R.self, where: descriptor.predicate, page: descriptor.page)
    }
}
