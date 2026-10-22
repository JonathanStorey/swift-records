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
/// container's `mainContext`. The array's order is saved too, so moves persist. To show records in
/// another order, sort a copy for display.
///
/// It can also load records by ID, such as an inverse's owners or one record a view was handed:
///
/// ```swift
/// @Records(ids: recipe.cookbookIDs) var cookbooks: [Cookbook]
/// @Records(id: recipeID) var recipe: Recipe?
/// ```
///
/// Writing a record to `$recipe` saves it, and writing `nil` deletes it.
///
/// Without a zone, the wrapper uses the environment's container, or the default zone's shared container
/// when there is none. With a zone, such as `@Records("pantry")`, it uses the environment's container if
/// that container belongs to the zone, and otherwise the zone's shared container.
@MainActor
@propertyWrapper
public struct Records<Value: Sendable>: DynamicProperty {
    @Environment(\.recordContainer) private var container
    @State private var cache = Cache()

    private let zone: Zone?
    private let query: Query
    private let animation: Animation?

    /// What a wrapper fetches and how it writes back, so lists and single records share one cache. Its
    /// key is a `UUID` or a `Set<UUID>`, and its closures are main-actor isolated, so it is safe to send.
    struct Query: @unchecked Sendable {
        /// Identifies the query's arguments, such as the IDs, so changing them fetches again.
        let key: AnyHashable?
        let empty: Value
        let fetch: @MainActor (RecordContainer) throws -> Value
        /// Re-applies the filter to values the cache already holds, after a save of this view's own edits.
        let refilter: (@MainActor (Value) -> Value)?
        let write: @MainActor (RecordsContext, _ new: Value, _ previous: Value, _ source: ObjectIdentifier) -> Void
    }

    private init(zone: Zone?, query: Query, animation: Animation?) {
        self.zone = zone
        self.query = query
        self.animation = animation
    }

    /// Records from the environment's container, or from the default zone when there is none, in their
    /// stored order. With an animation, the view animates as records arrive, change and leave.
    public init<R: Record>(filter predicate: Predicate<R>? = nil, animation: Animation? = nil) where Value == [R] {
        self.init(zone: nil, query: .list(predicate), animation: animation)
    }

    /// Records from a zone, such as `@Records(.pantry)`.
    public init<R: Record>(_ zone: Zone, filter predicate: Predicate<R>? = nil, animation: Animation? = nil) where Value == [R] {
        self.init(zone: zone, query: .list(predicate), animation: animation)
    }

    /// Records from a zone by name, such as `@Records("pantry")`.
    public init<R: Record>(_ zone: String, filter predicate: Predicate<R>? = nil, animation: Animation? = nil) where Value == [R] {
        self.init(Zone(zone), filter: predicate, animation: animation)
    }

    /// The records with these IDs in their stored order, such as an inverse's owners:
    /// `@Records(ids: recipe.cookbookIDs) var cookbooks: [Cookbook]`.
    public init<R: Record>(ids: Set<UUID>, animation: Animation? = nil) where Value == [R] {
        self.init(zone: nil, query: .list(ids: ids), animation: animation)
    }

    /// The records with these IDs in a zone.
    public init<R: Record>(_ zone: Zone, ids: Set<UUID>, animation: Animation? = nil) where Value == [R] {
        self.init(zone: zone, query: .list(ids: ids), animation: animation)
    }

    /// The record with this ID, or `nil` once it's deleted: `@Records(id: recipeID) var recipe: Recipe?`.
    public init<R: Record>(id: UUID, animation: Animation? = nil) where Value == R? {
        self.init(zone: nil, query: .single(id: id), animation: animation)
    }

    /// The record with this ID in a zone.
    public init<R: Record>(_ zone: Zone, id: UUID, animation: Animation? = nil) where Value == R? {
        self.init(zone: zone, query: .single(id: id), animation: animation)
    }

    /// The main context of the environment's container when it fits the requested zone, otherwise of the
    /// zone's shared container.
    private var resolvedContext: RecordsContext? {
        if let container, zone == nil || container.zone == zone {
            return container.mainContext
        }
        do {
            return try RecordContainer.shared(zone ?? .default).mainContext
        } catch {
            assertionFailure("@Records could not open zone \(zone ?? .default): \(error)")
            return nil
        }
    }

    public var wrappedValue: Value {
        cache.animation = animation
        return Self.value(context: resolvedContext, cache: cache, query: query)
    }

    public var projectedValue: Binding<Value> {
        let context = resolvedContext
        let cache = cache
        let query = query
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    Self.value(context: context, cache: cache, query: query)
                }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    guard let context else { return }
                    let previous = Self.value(context: context, cache: cache, query: query)
                    // Show the edit immediately; the context saves it once edits pause.
                    cache.value = newValue
                    query.write(context, newValue, previous, ObjectIdentifier(cache))
                }
            }
        )
    }

    private static func value(context: RecordsContext?, cache: Cache, query: Query) -> Value {
        guard let context else { return query.empty }
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
        if let value = cache.value, cache.key == query.key, changeCount == cache.changeCount + 1,
           context.lastSaveSource == ObjectIdentifier(cache) {
            // The save only wrote this view's own edits, which the cache already shows. Filter in memory
            // so an edited record still leaves, without reading the database again.
            if let refilter = query.refilter {
                cache.value = refilter(value)
            }
            cache.changeCount = changeCount
        } else if cache.changeCount != changeCount || cache.value == nil || cache.key != query.key {
            cache.value = (try? query.fetch(context.container)) ?? query.empty
            cache.changeCount = changeCount
            cache.key = query.key
        }
        return cache.value ?? query.empty
    }

    @MainActor
    @Observable
    final class Cache {
        var version = 0
        @ObservationIgnored var value: Value?
        @ObservationIgnored var key: AnyHashable?
        @ObservationIgnored var changeCount = -1
        @ObservationIgnored weak var context: RecordsContext?
        @ObservationIgnored var animation: Animation?
    }
}

extension Records.Query {
    static func list<R: Record>(_ predicate: Predicate<R>?) -> Self where Value == [R] {
        var refilter: (@MainActor ([R]) -> [R])?
        if let predicate {
            refilter = { records in (try? records.filter { try predicate.evaluate($0) }) ?? records }
        }
        return Self(
            key: nil,
            empty: [],
            fetch: { try $0.fetch(R.self, where: predicate) },
            refilter: refilter,
            write: { context, new, previous, source in context.apply(new, replacing: previous, source: source) }
        )
    }

    static func list<R: Record>(ids: Set<UUID>) -> Self where Value == [R] {
        Self(
            key: AnyHashable(ids),
            empty: [],
            fetch: { try $0.fetch(R.self, ids: ids) },
            refilter: { records in records.filter { ids.contains($0.id) } },
            write: { context, new, previous, source in context.apply(new, replacing: previous, source: source) }
        )
    }

    static func single<R: Record>(id: UUID) -> Self where Value == R? {
        Self(
            key: AnyHashable(id),
            empty: nil,
            fetch: { try $0.fetch(R.self, id: id) },
            refilter: nil,
            write: { context, new, previous, _ in
                if let new {
                    context.save(new)
                } else if let previous {
                    context.delete(previous)
                }
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

extension View {
    /// Makes a container available to `@Records` in this view and its children.
    public func recordContainer(_ container: RecordContainer) -> some View {
        environment(\.recordContainer, container)
    }
}
#endif
