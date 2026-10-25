#if canImport(SwiftUI)
import Foundation
import Observation
import SwiftUI

/// Fetches records for a SwiftUI view and keeps them current.
///
/// ```swift
/// @Records var todos: [ToDo]
///
/// List($todos, editActions: .all) { $todo in
///     TextField("Title", text: $todo.title)
/// }
/// ```
///
/// `todos` is a plain array, and `$todos` a `Binding<Records<ToDo>.Results>` that `List` and `ForEach`
/// edit as they would an array's. Writing to it inserts, updates and deletes records through the
/// container's `mainContext`. Records come sorted as `@Query` sorts them, and by ID without a sort:
///
/// ```swift
/// @Records(sort: \.servings, order: .reverse) var recipes: [Recipe]
/// @Records(filter: #Predicate<Recipe> { $0.servings > 2 }, sort: [SortDescriptor(\.title)]) var large: [Recipe]
/// ```
///
/// The array's order isn't stored. An edit through the binding moves the record to where it sorts, and
/// moving rows changes nothing. With a `fetchLimit`, `$todos.page += 1` shows the next page and
/// `$todos.appendNextPage()` grows the list, while `$todos.totalCount` counts every match. Changes
/// animate with the default animation unless you pass another, or `nil` for none.
///
/// It can also load records by ID, such as an inverse's owners:
///
/// ```swift
/// @Records(ids: recipe.cookbookIDs) var cookbooks: [Cookbook]
/// ```
///
/// It reads through the main context of the environment's container, or of a shared container on the
/// default folder when the environment has none. Without a zone it follows the context's `zone`, so setting
/// `context.zone` switches it and it fetches again. A zone, such as `@Records("pantry")`, pins it to that
/// zone whatever the context's is, and `@Records(.default)` pins it to the default zone.
@MainActor
@propertyWrapper
public struct Records<R: Record>: DynamicProperty {
    @Environment(\.recordContainer) private var container
    @State private var cache = Cache()

    /// What `$todos` binds to: the records with their place in the full result.
    public typealias Results = RecordResults<R>

    private let zone: ZoneChoice
    private let query: Query
    private let animation: Animation?

    /// What a wrapper fetches and how it writes back. Its key is hashable values, and its closures are
    /// main-actor isolated, so it is safe to send.
    struct Query: @unchecked Sendable {
        /// Identifies the query's arguments, such as the IDs, so changing them fetches again.
        let key: AnyHashable?
        /// The page the arguments ask for, which the view's paging can move.
        let page: RecordPage
        let fetch: @MainActor (ZoneStorage, RecordPage) throws -> [R]
        /// Counts every match, for a paged list's `totalCount`.
        let count: (@MainActor (ZoneStorage) throws -> Int)?
        /// Re-applies the filter to records the cache already holds, after a save of this view's own edits.
        let refilter: (@MainActor ([R]) -> [R])?
        /// Writes a binding's new value to the context and returns what the view shows: the records in the
        /// query's order, since the array's order isn't stored.
        let write: @MainActor (RecordContext, _ zone: Zone, _ new: [R], _ previous: [R], _ source: ObjectIdentifier) -> [R]
        /// Lays the context's unsaved changes over fetched records, so views show them before they commit.
        let overlay: @MainActor (RecordContext, _ zone: Zone, _ stored: [R], RecordPage) -> [R]
    }

    /// Whether the wrapper follows the context's zone or stays in one.
    enum ZoneChoice {
        case following
        case fixed(Zone)

        init(_ zone: Zone?) {
            self = zone.map { .fixed($0) } ?? .following
        }

        @MainActor
        func zone(in context: RecordContext) -> Zone {
            switch self {
            case .following: context.zone
            case .fixed(let zone): zone
            }
        }
    }

    private init(zone: Zone?, query: Query, animation: Animation?) {
        self.zone = ZoneChoice(zone)
        self.query = query
        self.animation = animation
    }

    /// The records a descriptor matches, as `@Query` takes a `FetchDescriptor`. A zone pins the wrapper to it
    /// whatever the context's is, and `nil` follows the context. With a `fetchLimit`, the view shows at most
    /// that many, so `RecordDescriptor<Recipe>(fetchLimit: 20)` shows the first 20.
    public init(_ zone: Zone?, _ descriptor: RecordDescriptor<R>, animation: Animation? = .default) {
        self.init(zone: zone, query: .list(descriptor), animation: animation)
    }

    /// Records in the descriptors' order and then by ID. `@Records var recipes: [Recipe]` takes every record,
    /// and `@Records("pantry")` pins the wrapper to a zone. It lives here rather than in an extension because
    /// only an initializer in the type's body lets a bare `@Records` stay out of a memberwise initializer.
    public init(
        _ zone: Zone? = nil, filter predicate: Predicate<R>? = nil, sort: [SortDescriptor<R>] = [],
        animation: Animation? = .default
    ) {
        self.init(zone, RecordDescriptor(predicate: predicate, sortBy: sort), animation: animation)
    }

    /// The main context of the environment's container, otherwise of the shared one.
    private var resolvedContext: RecordContext? {
        if let container {
            return container.mainContext
        }
        do {
            return try RecordContainer.shared().mainContext
        } catch {
            assertionFailure("@Records could not open the default folder: \(error)")
            return nil
        }
    }

    public var wrappedValue: [R] {
        cache.animation = animation
        return Self.value(context: resolvedContext, cache: cache, query: query, zone: zone)
    }

    /// The records as `Results`, whose indices are positions in the full result. Writing to it
    /// inserts, updates and deletes records, and `$todos.page`, `appendNextPage()` and `refresh()` move
    /// through it.
    public var projectedValue: Binding<Results> {
        let context = resolvedContext
        let cache = cache
        let query = query
        let choice = zone
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    let elements = Self.value(context: context, cache: cache, query: query, zone: choice)
                    let page = cache.key?.page ?? query.page
                    return RecordResults(
                        elements, page: page,
                        totalCount: page.isPaged ? cache.totalCount : nil,
                        hasChanges: context?.hasPendingChanges(from: ObjectIdentifier(cache)) ?? false, pager: cache
                    )
                }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    guard let context else { return }
                    let previous = Self.value(context: context, cache: cache, query: query, zone: choice)
                    // Show the edit immediately. The context saves it once edits pause.
                    cache.value = query.write(context, choice.zone(in: context), newValue.elements, previous, ObjectIdentifier(cache))
                    cache.version += 1
                }
            }
        )
    }

    private static func value(context: RecordContext?, cache: Cache, query: Query, zone choice: ZoneChoice) -> [R] {
        guard let context else { return [] }
        // Reading the cache's version registers the dependency. The context bumps it after each change,
        // inside the view's animation.
        _ = cache.version
        if cache.context !== context {
            cache.context = context
            context.onChange(for: cache) { [weak cache] in
                guard let cache else { return }
                withAnimation(cache.animation) { cache.version += 1 }
            }
        }
        let changeCount = context.changeCount
        let zone = choice.zone(in: context)
        let page = cache.page(for: query)
        let key = CacheKey(query: query.key, zone: zone, page: page)
        let source = ObjectIdentifier(cache)
        if var value = cache.value, cache.key == key, changeCount == cache.changeCount + 1,
           context.lastSaveSource == source {
            // The save only wrote this view's own edits, which the cache already shows. Filter in memory
            // so an edited record still leaves, without reading the database again.
            if let refilter = query.refilter {
                value = refilter(value)
            }
            cache.value = value
            cache.stored = value
            cache.changeCount = changeCount
            if page.isPaged, let storage = try? context.storage(for: zone) {
                cache.totalCount = (try? query.count?(storage)) ?? cache.totalCount
            }
        } else if cache.changeCount != changeCount || cache.value == nil || cache.key != key {
            // If the fetch fails, such as while another process holds the file, the view keeps what it
            // showed rather than go blank. A new query has nothing to keep, so it shows nothing.
            let previous = cache.key == key ? cache.stored : nil
            let storage = try? context.storage(for: zone)
            let stored = (try? storage.map { try query.fetch($0, page) }) ?? previous ?? []
            if page.isPaged, let storage {
                cache.totalCount = (try? query.count?(storage)) ?? (cache.key == key ? cache.totalCount : nil)
            }
            cache.stored = stored
            cache.value = query.overlay(context, zone, stored, page)
            cache.changeCount = changeCount
            cache.key = key
        } else if context.sequence != cache.sequence,
                  context.hasPendingChanges(after: cache.sequence, excluding: source),
                  let stored = cache.stored {
            // Another view or code changed records without saving yet. This view's own edits are
            // already in the cache, so they need no work.
            cache.value = query.overlay(context, zone, stored, page)
        }
        cache.sequence = context.sequence
        return cache.value ?? []
    }

    /// What the cached value was fetched for.
    struct CacheKey: Hashable {
        let query: AnyHashable?
        let zone: Zone
        let page: RecordPage
    }

    @MainActor
    @Observable
    final class Cache: RecordPager {
        var version = 0
        /// What the view shows: the fetched records with unsaved changes laid over them.
        @ObservationIgnored var value: [R]?
        /// The records as fetched.
        @ObservationIgnored var stored: [R]?
        /// The context's last change number this cache has seen.
        @ObservationIgnored var sequence = 0
        @ObservationIgnored var key: CacheKey?
        @ObservationIgnored var changeCount = -1
        @ObservationIgnored weak var context: RecordContext?
        @ObservationIgnored var animation: Animation?
        /// Every match, read with each fetch of a paged list.
        @ObservationIgnored var totalCount: Int?
        /// The page the view moved to, for the query it moved in. A new query starts at its own page.
        @ObservationIgnored var moved: (query: AnyHashable?, page: RecordPage)?

        func page(for query: Query) -> RecordPage {
            if let moved, moved.query == query.key {
                return moved.page
            }
            return query.page
        }

        func move(to page: RecordPage) {
            moved = (key?.query, page)
            withAnimation(animation) { version += 1 }
        }

        func refresh() async throws {
            try await context?.refresh()
        }

        func save() throws {
            try context?.save()
        }
    }
}

extension Records {
    /// The records with these IDs, sorted by ID, such as an inverse's owners:
    /// `@Records(ids: recipe.cookbookIDs) var cookbooks: [Cookbook]`.
    public init(_ zone: Zone? = nil, ids: Set<R.ID>, animation: Animation? = .default) {
        self.init(zone: zone, query: .list(ids: ids), animation: animation)
    }

    /// The records a descriptor matches in the context's current zone.
    public init(_ descriptor: RecordDescriptor<R>, animation: Animation? = .default) {
        self.init(nil, descriptor, animation: animation)
    }

    /// Records sorted by one property, as `@Query(sort: \.title)`.
    public init<Property: Comparable>(
        _ zone: Zone? = nil, filter predicate: Predicate<R>? = nil, sort keyPath: any KeyPath<R, Property> & Sendable,
        order: SortOrder = .forward, animation: Animation? = .default
    ) {
        self.init(zone, filter: predicate, sort: [SortDescriptor(keyPath, order: order)], animation: animation)
    }

    /// Records sorted by one optional property, with `nil` first in forward order.
    public init<Property: Comparable>(
        _ zone: Zone? = nil, filter predicate: Predicate<R>? = nil, sort keyPath: any KeyPath<R, Property?> & Sendable,
        order: SortOrder = .forward, animation: Animation? = .default
    ) {
        self.init(zone, filter: predicate, sort: [SortDescriptor(keyPath, order: order)], animation: animation)
    }
}

extension Records.Query {
    static func list(_ descriptor: RecordDescriptor<R>) -> Self {
        let predicate = descriptor.predicate
        let order = RecordOrder(descriptor.sortBy)
        var refilter: (@MainActor ([R]) -> [R])?
        if let predicate {
            refilter = { records in (try? records.filter { try predicate.evaluate($0) }) ?? records }
        }
        return Self(
            // A new filter or sort fetches again. The page is part of the cache's key.
            key: AnyHashable([predicate.map(PredicateFingerprint.of), AnyHashable(descriptor.sortBy)]),
            page: RecordPage(limit: descriptor.fetchLimit, offset: descriptor.fetchOffset ?? 0),
            fetch: { storage, page in try storage.fetch(page.applied(to: descriptor)) },
            count: { try $0.count(R.self, where: predicate) },
            refilter: refilter,
            write: { context, zone, new, previous, source in
                context.apply(new, replacing: previous, in: zone, source: source, order: order)
            },
            overlay: { context, zone, stored, page in
                let records = context.overlay(stored, in: zone, order: order) { (try? predicate?.evaluate($0)) ?? true }
                // A page still holds at most its limit with unsaved records added.
                return page.readLimit.map { Array(records.prefix($0)) } ?? records
            }
        )
    }

    static func list(ids: Set<R.ID>) -> Self {
        Self(
            key: AnyHashable(ids),
            page: RecordPage(),
            fetch: { storage, _ in try storage.fetch(R.self, ids: ids) },
            count: nil,
            refilter: { records in records.filter { ids.contains($0.id) } },
            write: { context, zone, new, previous, source in context.apply(new, replacing: previous, in: zone, source: source) },
            overlay: { context, zone, stored, _ in
                context.overlay(stored, in: zone) { ids.contains($0.id) }
            }
        )
    }
}

/// Paging read naturally off `$todos`, such as `$todos.page += 1`.
@MainActor
extension Binding where Value: RecordResultsProtocol {
    /// Every saved record the query matches, not only the page's.
    public var totalCount: Int { wrappedValue.totalCount }
    /// The page size the descriptor chose, or `nil` for no limit.
    public var fetchLimit: Int? { wrappedValue.fetchLimit }
    /// How many records come before the page.
    public var fetchOffset: Int { wrappedValue.fetchOffset }
    /// The page's number from 0. Setting it shows that page, up to the last.
    public var page: Int {
        get { wrappedValue.page }
        nonmutating set { wrappedValue.show(page: newValue) }
    }
    /// How many pages the full result fills, at least 1.
    public var pageCount: Int { wrappedValue.pageCount }
    public var hasNextPage: Bool { wrappedValue.hasNextPage }
    public var hasPreviousPage: Bool { wrappedValue.hasPreviousPage }
    /// Whether edits made through this list are still waiting to save.
    public var hasChanges: Bool { wrappedValue.hasChanges }

    /// Shows the next page, if there is one.
    public func nextPage() {
        wrappedValue.nextPage()
    }

    /// Shows the previous page, if there is one.
    public func previousPage() {
        wrappedValue.previousPage()
    }

    /// Appends the next page, for an endless list's last row. `fetchLimit` stays the page size.
    public func appendNextPage() {
        wrappedValue.appendNextPage()
    }

    /// Saves, picks up other processes' changes, and syncs, for `.refreshable`.
    public func refresh() async throws {
        try await wrappedValue.refresh()
    }

    /// Saves the context's pending changes now rather than once edits pause.
    public func save() throws {
        try wrappedValue.save()
    }
}

private struct RecordContainerKey: EnvironmentKey {
    static let defaultValue: RecordContainer? = nil
}

extension EnvironmentValues {
    /// The container that `@Records` in this view uses, when one was set with `recordContainer(_:)`.
    public var recordContainer: RecordContainer? {
        get { self[RecordContainerKey.self] }
        set { self[RecordContainerKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// The context views use for their own changes, as SwiftData's `modelContext`: the main context of the
    /// environment's container, or of the default zone's shared container when none is set.
    ///
    /// ```swift
    /// @Environment(\.recordContext) private var context
    /// ```
    public var recordContext: RecordContext {
        let container = recordContainer
        // SwiftUI reads the environment on the main actor.
        return MainActor.assumeIsolated {
            if let container {
                return container.mainContext
            }
            do {
                return try RecordContainer.shared().mainContext
            } catch {
                preconditionFailure("SwiftRecords could not open the default zone: \(error)")
            }
        }
    }
}

extension View {
    /// Makes a container, and its main context as `\.recordContext`, available to this view and its children.
    public func recordContainer(_ container: RecordContainer) -> some View {
        environment(\.recordContainer, container)
    }
}
#endif
