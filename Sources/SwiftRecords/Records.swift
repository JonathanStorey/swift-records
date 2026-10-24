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
/// It reads through the main context of the environment's container, or of a shared container on the
/// default folder when the environment has none. Without a zone it follows the context's `zone`, so setting
/// `context.zone` switches it and it fetches again. A zone, such as `@Records("pantry")`, pins it to that
/// zone whatever the context's is, and `@Records(.default)` pins it to the default zone.
@MainActor
@propertyWrapper
public struct Records<Value: Sendable>: DynamicProperty {
    @Environment(\.recordContainer) private var container
    @State private var cache = Cache()

    private let zone: ZoneChoice
    private let query: Query
    private let animation: Animation?

    /// What a wrapper fetches and how it writes back, so lists and single records share one cache. Its
    /// key is a `UUID` or a `Set<UUID>`, and its closures are main-actor isolated, so it is safe to send.
    struct Query: @unchecked Sendable {
        /// Identifies the query's arguments, such as the IDs, so changing them fetches again.
        let key: AnyHashable?
        let empty: Value
        let fetch: @MainActor (ZoneStorage) throws -> Value
        /// Re-applies the filter to values the cache already holds, after a save of this view's own edits.
        let refilter: (@MainActor (Value) -> Value)?
        let write: @MainActor (RecordContext, _ zone: Zone, _ new: Value, _ previous: Value, _ source: ObjectIdentifier) -> Void
        /// Lays the context's unsaved changes over fetched values, so views show them before they commit.
        let overlay: @MainActor (RecordContext, _ zone: Zone, _ stored: Value, _ source: ObjectIdentifier) -> Value
    }

    /// Whether the wrapper follows the context's zone or stays in one.
    enum ZoneChoice {
        case following
        case fixed(Zone)

        @MainActor
        func zone(in context: RecordContext) -> Zone {
            switch self {
            case .following: context.zone
            case .fixed(let zone): zone
            }
        }
    }

    private init(zone: ZoneChoice, query: Query, animation: Animation?) {
        self.zone = zone
        self.query = query
        self.animation = animation
    }

    /// Records from the context's current zone, in their stored order. With an animation, the view animates as records arrive, change and leave.
    public init<R: Record>(filter predicate: Predicate<R>? = nil, animation: Animation? = nil) where Value == [R] {
        self.init(zone: .following, query: .list(RecordDescriptor(predicate: predicate)), animation: animation)
    }

    /// The records a descriptor matches, as `@Query` takes a `FetchDescriptor`. With a `fetchLimit`, the
    /// view shows at most that many, so `RecordDescriptor<Recipe>(fetchLimit: 20)` shows the first 20.
    public init<R: Record>(_ descriptor: RecordDescriptor<R>, animation: Animation? = nil) where Value == [R] {
        self.init(zone: .following, query: .list(descriptor), animation: animation)
    }

    /// The records a descriptor matches in one zone, whatever the context's is.
    public init<R: Record>(_ zone: Zone, _ descriptor: RecordDescriptor<R>, animation: Animation? = nil) where Value == [R] {
        self.init(zone: .fixed(zone), query: .list(descriptor), animation: animation)
    }

    /// Every record of the element type, so `@Records var recipes: [Recipe]` needs no arguments and stays
    /// out of the view's memberwise initializer.
    public init() where Value: RecordArray {
        self.init(zone: .following, query: Value.allRecordsQuery(), animation: nil)
    }

    /// Records from one zone whatever the context's is, such as `@Records("pantry")`. Pass `.default` for the default zone.
    public init<R: Record>(_ zone: Zone, filter predicate: Predicate<R>? = nil, animation: Animation? = nil) where Value == [R] {
        self.init(zone: .fixed(zone), query: .list(RecordDescriptor(predicate: predicate)), animation: animation)
    }

    /// The records with these IDs in their stored order, such as an inverse's owners:
    /// `@Records(ids: recipe.cookbookIDs) var cookbooks: [Cookbook]`.
    public init<R: Record>(ids: Set<UUID>, animation: Animation? = nil) where Value == [R] {
        self.init(zone: .following, query: .list(ids: ids), animation: animation)
    }

    /// The records with these IDs in a zone.
    public init<R: Record>(_ zone: Zone, ids: Set<UUID>, animation: Animation? = nil) where Value == [R] {
        self.init(zone: .fixed(zone), query: .list(ids: ids), animation: animation)
    }

    /// The record with this ID, or `nil` once it's deleted: `@Records(id: recipeID) var recipe: Recipe?`.
    public init<R: Record>(id: UUID, animation: Animation? = nil) where Value == R? {
        self.init(zone: .following, query: .single(id: id), animation: animation)
    }

    /// The record with this ID in a zone.
    public init<R: Record>(_ zone: Zone, id: UUID, animation: Animation? = nil) where Value == R? {
        self.init(zone: .fixed(zone), query: .single(id: id), animation: animation)
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

    public var wrappedValue: Value {
        cache.animation = animation
        return Self.value(context: resolvedContext, cache: cache, query: query, zone: zone)
    }

    public var projectedValue: Binding<Value> {
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
                    // Show the edit immediately; the context saves it once edits pause.
                    cache.value = newValue
                    cache.version += 1
                    query.write(context, choice.zone(in: context), newValue, previous, ObjectIdentifier(cache))
                }
            }
        )
    }

    private static func value(context: RecordContext?, cache: Cache, query: Query, zone choice: ZoneChoice) -> Value {
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
            let stored = (try? query.fetch(context.storage(for: zone))) ?? previous ?? query.empty
            cache.stored = stored
            cache.value = query.overlay(context, zone, stored, source)
            cache.changeCount = changeCount
            cache.key = key
        } else if context.sequence != cache.sequence,
                  context.hasPendingChanges(after: cache.sequence, excluding: source),
                  let stored = cache.stored {
            // Another view or code changed records without saving yet. This view's own edits are
            // already in the cache, so they need no work.
            cache.value = query.overlay(context, zone, stored, source)
        }
        cache.sequence = context.sequence
        return cache.value ?? query.empty
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
        @ObservationIgnored var value: Value?
        /// The records as fetched.
        @ObservationIgnored var stored: Value?
        /// The context's last change number this cache has seen.
        @ObservationIgnored var sequence = 0
        @ObservationIgnored var key: CacheKey?
        @ObservationIgnored var changeCount = -1
        @ObservationIgnored weak var context: RecordContext?
        @ObservationIgnored var animation: Animation?
    }
}

extension Records.Query {
    static func list<R: Record>(_ descriptor: RecordDescriptor<R>) -> Self where Value == [R] {
        let predicate = descriptor.predicate
        let limit = descriptor.fetchLimit
        var refilter: (@MainActor ([R]) -> [R])?
        if let predicate {
            refilter = { records in (try? records.filter { try predicate.evaluate($0) }) ?? records }
        }
        return Self(
            // A new filter or page fetches again.
            key: AnyHashable([
                predicate.map(PredicateFingerprint.of), descriptor.fetchLimit.map(AnyHashable.init),
                AnyHashable(descriptor.fetchOffset),
            ]),
            empty: [],
            fetch: { try $0.fetch(descriptor) },
            refilter: refilter,
            write: { context, zone, new, previous, source in context.apply(new, replacing: previous, in: zone, source: source) },
            overlay: { context, zone, stored, source in
                let records = context.overlay(stored, in: zone, source: source) { (try? predicate?.evaluate($0)) ?? true }
                // Unsaved records join the end, so a page still holds at most its limit.
                return limit.map { Array(records.prefix($0)) } ?? records
            }
        )
    }

    static func list<R: Record>(ids: Set<UUID>) -> Self where Value == [R] {
        Self(
            key: AnyHashable(ids),
            empty: [],
            fetch: { try $0.fetch(R.self, ids: ids) },
            refilter: { records in records.filter { ids.contains($0.id) } },
            write: { context, zone, new, previous, source in context.apply(new, replacing: previous, in: zone, source: source) },
            overlay: { context, zone, stored, source in
                context.overlay(stored, in: zone, source: source) { ids.contains($0.id) }
            }
        )
    }

    static func single<R: Record>(id: UUID) -> Self where Value == R? {
        Self(
            key: AnyHashable(id),
            empty: nil,
            fetch: { try $0.fetch(R.self, id: id) },
            refilter: nil,
            write: { context, zone, new, previous, _ in
                if let new {
                    // The wrapper is bound to one ID, so a record with another one can only be a mistake.
                    guard new.id == id else {
                        assertionFailure("@Records(id:) is bound to \(id), so its record's id can't change to \(new.id)")
                        return
                    }
                    context.insert(new, in: zone)
                } else if let previous {
                    context.delete(previous, in: zone)
                }
            },
            overlay: { context, zone, stored, _ in context.overlay(stored, id: id, in: zone) }
        )
    }
}

/// An array of records, which `@Records` fills when it's declared without arguments, as in
/// `@Records var recipes: [Recipe]`.
public protocol RecordArray: Sendable {
    associatedtype RecordElement: Record
}

extension Array: RecordArray where Element: Record {
    public typealias RecordElement = Element
}

extension RecordArray {
    /// Every record of the element type, typed as this array. Only `[R]` conforms, so the casts hold.
    @MainActor
    static func allRecordsQuery() -> Records<Self>.Query {
        typealias R = RecordElement
        let query = Records<[R]>.Query.list(RecordDescriptor<R>())
        let fetch: @MainActor (ZoneStorage) throws -> Self = { try query.fetch($0) as! Self }
        var refilter: (@MainActor (Self) -> Self)?
        if let filter = query.refilter {
            refilter = { filter($0 as! [R]) as! Self }
        }
        let write: @MainActor (RecordContext, Zone, Self, Self, ObjectIdentifier) -> Void = { context, zone, new, previous, source in
            query.write(context, zone, new as! [R], previous as! [R], source)
        }
        let overlay: @MainActor (RecordContext, Zone, Self, ObjectIdentifier) -> Self = { context, zone, stored, source in
            query.overlay(context, zone, stored as! [R], source) as! Self
        }
        return Records<Self>.Query(
            key: query.key, empty: query.empty as! Self, fetch: fetch, refilter: refilter, write: write, overlay: overlay
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
