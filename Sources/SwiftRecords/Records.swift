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
/// `$todos` is a real `Binding<[ToDo]>`. Writing to it inserts, updates and deletes records through the
/// container's `mainContext`. Records come sorted as `@Query` sorts them, and by ID without a sort:
///
/// ```swift
/// @Records(sort: \.servings, order: .reverse) var recipes: [Recipe]
/// @Records(filter: #Predicate<Recipe> { $0.servings > 2 }, sort: [SortDescriptor(\.title)]) var large: [Recipe]
/// ```
///
/// The array's order isn't stored. An edit through the binding moves the record to where it sorts, and
/// moving rows changes nothing. Changes animate with the default animation unless you pass another, or
/// `nil` for none.
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

    private let zone: ZoneChoice
    private let query: Query
    private let animation: Animation?

    /// What a wrapper fetches and how it writes back. Its key is hashable values, and its closures are
    /// main-actor isolated, so it is safe to send.
    struct Query: @unchecked Sendable {
        /// Identifies the query's arguments, such as the IDs, so changing them fetches again.
        let key: AnyHashable?
        let fetch: @MainActor (ZoneStorage) throws -> [R]
        /// Re-applies the filter to records the cache already holds, after a save of this view's own edits.
        let refilter: (@MainActor ([R]) -> [R])?
        /// Writes a binding's new value to the context and returns what the view shows: the records in the
        /// query's order, since the array's order isn't stored.
        let write: @MainActor (RecordContext, _ zone: Zone, _ new: [R], _ previous: [R], _ source: ObjectIdentifier) -> [R]
        /// Lays the context's unsaved changes over fetched records, so views show them before they commit.
        let overlay: @MainActor (RecordContext, _ zone: Zone, _ stored: [R]) -> [R]
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

    public var projectedValue: Binding<[R]> {
        let context = resolvedContext
        let cache = cache
        let query = query
        let choice = zone
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    Self.value(context: context, cache: cache, query: query, zone: choice)
                }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    guard let context else { return }
                    let previous = Self.value(context: context, cache: cache, query: query, zone: choice)
                    // Show the edit immediately. The context saves it once edits pause.
                    cache.value = query.write(context, choice.zone(in: context), newValue, previous, ObjectIdentifier(cache))
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
        let key = CacheKey(query: query.key, zone: zone)
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
        } else if cache.changeCount != changeCount || cache.value == nil || cache.key != key {
            // If the fetch fails, such as while another process holds the file, the view keeps what it
            // showed rather than go blank. A new query has nothing to keep, so it shows nothing.
            let previous = cache.key == key ? cache.stored : nil
            let stored = (try? query.fetch(context.storage(for: zone))) ?? previous ?? []
            cache.stored = stored
            cache.value = query.overlay(context, zone, stored)
            cache.changeCount = changeCount
            cache.key = key
        } else if context.sequence != cache.sequence,
                  context.hasPendingChanges(after: cache.sequence, excluding: source),
                  let stored = cache.stored {
            // Another view or code changed records without saving yet. This view's own edits are
            // already in the cache, so they need no work.
            cache.value = query.overlay(context, zone, stored)
        }
        cache.sequence = context.sequence
        return cache.value ?? []
    }

    /// What the cached value was fetched for.
    struct CacheKey: Hashable {
        let query: AnyHashable?
        let zone: Zone
    }

    @MainActor
    @Observable
    final class Cache {
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
        let limit = descriptor.fetchLimit
        let order = RecordOrder(descriptor.sortBy)
        var refilter: (@MainActor ([R]) -> [R])?
        if let predicate {
            refilter = { records in (try? records.filter { try predicate.evaluate($0) }) ?? records }
        }
        return Self(
            // A new filter, sort or page fetches again.
            key: AnyHashable([
                predicate.map(PredicateFingerprint.of), AnyHashable(descriptor.sortBy), descriptor.fetchLimit.map(AnyHashable.init),
                AnyHashable(descriptor.fetchOffset),
            ]),
            fetch: { try $0.fetch(descriptor) },
            refilter: refilter,
            write: { context, zone, new, previous, source in
                context.apply(new, replacing: previous, in: zone, source: source, order: order)
            },
            overlay: { context, zone, stored in
                let records = context.overlay(stored, in: zone, order: order) { (try? predicate?.evaluate($0)) ?? true }
                // A page still holds at most its limit with unsaved records added.
                return limit.map { Array(records.prefix($0)) } ?? records
            }
        )
    }

    static func list(ids: Set<R.ID>) -> Self {
        Self(
            key: AnyHashable(ids),
            fetch: { try $0.fetch(R.self, ids: ids) },
            refilter: { records in records.filter { ids.contains($0.id) } },
            write: { context, zone, new, previous, source in context.apply(new, replacing: previous, in: zone, source: source) },
            overlay: { context, zone, stored in
                context.overlay(stored, in: zone) { ids.contains($0.id) }
            }
        )
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
