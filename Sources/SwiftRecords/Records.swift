#if canImport(SwiftUI)
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
/// Without a zone, the wrapper uses the environment's container, or the default zone's shared container
/// when there is none. With a zone, such as `@Records("pantry")`, it uses the environment's container if
/// that container belongs to the zone, and otherwise the zone's shared container.
@MainActor
@propertyWrapper
public struct Records<R: Record>: DynamicProperty {
    @Environment(\.recordContainer) private var container
    @State private var cache = Cache()

    private let zone: Zone?
    private let predicate: Predicate<R>?
    private let animation: Animation?

    /// Records from the environment's container, or from the default zone when there is none, in their
    /// stored order. With an animation, the view animates as records arrive, change and leave.
    public init(filter predicate: Predicate<R>? = nil, animation: Animation? = nil) {
        zone = nil
        self.predicate = predicate
        self.animation = animation
    }

    /// Records from a zone, such as `@Records(.pantry)`.
    public init(_ zone: Zone, filter predicate: Predicate<R>? = nil, animation: Animation? = nil) {
        self.zone = zone
        self.predicate = predicate
        self.animation = animation
    }

    /// Records from a zone by name, such as `@Records("pantry")`.
    public init(_ zone: String, filter predicate: Predicate<R>? = nil, animation: Animation? = nil) {
        self.init(Zone(zone), filter: predicate, animation: animation)
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

    public var wrappedValue: [R] {
        cache.animation = animation
        return Self.records(context: resolvedContext, cache: cache, predicate: predicate)
    }

    public var projectedValue: Binding<[R]> {
        // Capture only Sendable values so the binding works under strict concurrency.
        let context = resolvedContext
        let cache = cache
        let predicate = predicate
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    Self.records(context: context, cache: cache, predicate: predicate)
                }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    guard let context else { return }
                    let previous = Self.records(context: context, cache: cache, predicate: predicate)
                    // Show the edit immediately; the context saves it once edits pause.
                    cache.records = newValue
                    context.apply(newValue, replacing: previous, source: ObjectIdentifier(cache))
                }
            }
        )
    }

    private static func records(context: RecordsContext?, cache: Cache, predicate: Predicate<R>?) -> [R] {
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
        if let records = cache.records, changeCount == cache.changeCount + 1,
           context.lastSaveSource == ObjectIdentifier(cache) {
            // The save only wrote this view's own edits, which the cache already shows. Filter in memory
            // so an edited record still leaves, without reading the database again.
            if let predicate {
                cache.records = (try? records.filter { try predicate.evaluate($0) }) ?? records
            }
            cache.changeCount = changeCount
        } else if cache.changeCount != changeCount || cache.records == nil {
            cache.records = (try? context.container.fetch(R.self, where: predicate)) ?? []
            cache.changeCount = changeCount
        }
        return cache.records ?? []
    }

    @MainActor
    @Observable
    final class Cache {
        var version = 0
        @ObservationIgnored var records: [R]?
        @ObservationIgnored var changeCount = -1
        @ObservationIgnored weak var context: RecordsContext?
        @ObservationIgnored var animation: Animation?
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
