import Foundation

/// The records `$todos` binds to, also named `Records<R>.Results`: the pages of a `@Records` query the
/// view holds, with their place in the full result.
///
/// Its indices are positions in the full result, so a page that skips 40 records runs from 40 up to
/// `fetchOffset + count`, as an array slice keeps its base's indices. `ForEach($todos)` and
/// `List($todos, editActions: .delete)` work as they do on an array. Inserts, edits and deletes write
/// through the main context. The order comes from the query's sort, so moving or swapping records changes
/// nothing.
public struct RecordResults<R: Record>: RandomAccessCollection, MutableCollection, RangeReplaceableCollection, Sendable {
    public typealias Index = Int

    /// The records the view holds, in the query's order.
    public internal(set) var elements: [R]
    /// How many records come before the page. `startIndex` is this offset.
    public let fetchOffset: Int
    /// The page size the descriptor chose, or `nil` for no limit. `appendNextPage()` adds pages without changing it.
    public let fetchLimit: Int?
    /// How many pages from `fetchOffset` the list holds, more than 1 after `appendNextPage()`.
    let pages: Int
    /// Every saved record the query matches, not only the page's.
    public let totalCount: Int
    /// Whether edits made through this list are still waiting for the context to save them.
    public let hasChanges: Bool
    /// The list's records whose saved changes the sync server hasn't confirmed. See `RecordContext.unsynced`.
    public let unsynced: Set<UUID>
    let pager: (any RecordPager)?

    init(
        _ elements: [R], page: RecordPage = RecordPage(), totalCount: Int? = nil, hasChanges: Bool = false,
        unsynced: Set<UUID> = [], pager: (any RecordPager)? = nil
    ) {
        self.elements = elements
        fetchOffset = page.offset
        fetchLimit = page.limit
        pages = page.pages
        self.totalCount = totalCount ?? page.offset + elements.count
        self.hasChanges = hasChanges
        self.unsynced = unsynced
        self.pager = pager
    }

    public init() {
        self.init([])
    }

    /// The first page's number from 0, its offset divided by its limit. A list without a limit is always
    /// page 0.
    public var page: Int {
        guard let fetchLimit, fetchLimit > 0 else { return 0 }
        return fetchOffset / fetchLimit
    }

    /// How many pages the full result fills, at least 1. A list without a limit is one page.
    public var pageCount: Int {
        guard let fetchLimit, fetchLimit > 0 else { return 1 }
        return Swift.max((totalCount + fetchLimit - 1) / fetchLimit, 1)
    }

    /// Whether records come after the list's last page.
    public var hasNextPage: Bool {
        guard let fetchLimit else { return false }
        return fetchOffset + fetchLimit * pages < totalCount
    }

    /// Whether records come before the page.
    public var hasPreviousPage: Bool { fetchOffset > 0 }

    public var startIndex: Int { fetchOffset }
    public var endIndex: Int { fetchOffset + elements.count }

    public subscript(position: Int) -> R {
        get { elements[position - fetchOffset] }
        set { elements[position - fetchOffset] = newValue }
    }

    public mutating func replaceSubrange<C: Collection>(_ subrange: Range<Int>, with newElements: C) where C.Element == R {
        elements.replaceSubrange((subrange.lowerBound - fetchOffset)..<(subrange.upperBound - fetchOffset), with: newElements)
    }

    /// Shows one page of the full result, from 0. Pages past the last show the last one, and a list
    /// without a limit has only page 0.
    @MainActor
    public func show(page: Int) {
        guard let fetchLimit, fetchLimit > 0 else { return }
        let page = Swift.min(Swift.max(page, 0), pageCount - 1)
        guard page * fetchLimit != fetchOffset || pages > 1 else { return }
        pager?.move(to: RecordPage(limit: fetchLimit, offset: page * fetchLimit))
    }

    /// Shows the page after the list's last one, if there is one.
    @MainActor
    public func nextPage() {
        guard hasNextPage else { return }
        show(page: page + pages)
    }

    /// Shows the page before this one, if there is one.
    @MainActor
    public func previousPage() {
        show(page: page - 1)
    }

    /// Appends the next page to the list, for an endless list's last row. `fetchLimit` stays the page
    /// size. A list without a limit, or already holding the rest of the result, has nothing more to load.
    @MainActor
    public func appendNextPage() {
        guard let fetchLimit, hasNextPage else { return }
        pager?.move(to: RecordPage(limit: fetchLimit, offset: fetchOffset, pages: pages + 1))
    }

    /// Saves, picks up other processes' changes, and syncs, as `RecordContext.refresh()` does, for
    /// pull-to-refresh.
    @MainActor
    public func refresh() async throws {
        try await pager?.refresh()
    }

    /// Saves the context's pending changes, this list's among them.
    @MainActor
    public func save() throws {
        try pager?.save()
    }
}

/// What lets `Binding<RecordResults<R>>` page through records, since an extension's properties can't be
/// generic over `R`.
public protocol RecordResultsProtocol {
    var totalCount: Int { get }
    var fetchLimit: Int? { get }
    var fetchOffset: Int { get }
    var page: Int { get }
    var pageCount: Int { get }
    var hasNextPage: Bool { get }
    var hasPreviousPage: Bool { get }
    var hasChanges: Bool { get }
    var unsynced: Set<UUID> { get }
    @MainActor func show(page: Int)
    @MainActor func nextPage()
    @MainActor func previousPage()
    @MainActor func appendNextPage()
    @MainActor func refresh() async throws
    @MainActor func save() throws
}

extension RecordResults: RecordResultsProtocol {}

/// Moves a `@Records` view's page and refreshes its context.
@MainActor
protocol RecordPager: AnyObject, Sendable {
    func move(to page: RecordPage)
    func refresh() async throws
    func save() throws
}

/// The part of a query's result a view holds: `pages` pages of `limit` records from `offset`.
struct RecordPage: Hashable {
    var limit: Int?
    var offset = 0
    var pages = 1

    var isPaged: Bool { limit != nil || offset > 0 }

    /// The most records the view reads, or `nil` for every one after the offset.
    var readLimit: Int? { limit.map { $0 * pages } }

    /// The descriptor reading only these pages.
    func applied<R>(to descriptor: RecordDescriptor<R>) -> RecordDescriptor<R> {
        var descriptor = descriptor
        descriptor.fetchLimit = readLimit
        descriptor.fetchOffset = offset > 0 ? offset : nil
        return descriptor
    }
}
