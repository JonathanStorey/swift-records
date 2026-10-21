#if canImport(SwiftUI)
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
/// `$todos` is a real `Binding<[ToDo]>`. Writing to it inserts, updates and deletes records through a
/// `RecordsContext`. The array's order is saved too, so moves persist. To show records in another
/// order, sort a copy for display, or fetch with sort descriptors through `RecordContainer`.
///
/// Without a zone, the wrapper uses the environment's context, or the default zone's shared context
/// when there is none. With a zone, such as `@Records("pantry")`, it uses the environment's context if
/// that context belongs to the zone, and otherwise the zone's shared context.
@MainActor
@propertyWrapper
public struct Records<R: Record>: DynamicProperty {
    @Environment(\.recordsContext) private var context
    @State private var cache = Cache()

    private let zone: Zone?
    private let predicate: Predicate<R>?

    /// Records from the environment's context, or from the default zone when there is none, in their
    /// stored order.
    public init(filter predicate: Predicate<R>? = nil) {
        zone = nil
        self.predicate = predicate
    }

    /// Records from a zone, such as `@Records(.pantry)`.
    public init(_ zone: Zone, filter predicate: Predicate<R>? = nil) {
        self.zone = zone
        self.predicate = predicate
    }

    /// Records from a zone by name, such as `@Records("pantry")`.
    public init(_ zone: String, filter predicate: Predicate<R>? = nil) {
        self.init(Zone(zone), filter: predicate)
    }

    /// The environment's context when it fits the requested zone, otherwise the zone's shared context.
    private var resolvedContext: RecordsContext? {
        if let context, zone == nil || context.container.zone == zone {
            return context
        }
        do {
            return try RecordsContext.shared(zone ?? .default)
        } catch {
            assertionFailure("@Records could not open zone \(zone ?? .default): \(error)")
            return nil
        }
    }

    public var wrappedValue: [R] {
        Self.records(context: resolvedContext, cache: cache, predicate: predicate)
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
                    context.apply(newValue, replacing: previous, keepOrder: true, source: ObjectIdentifier(cache))
                }
            }
        )
    }

    private static func records(context: RecordsContext?, cache: Cache, predicate: Predicate<R>?) -> [R] {
        guard let context else { return [] }
        // Reading changeCount registers the dependency, so the view updates after each save.
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
    private final class Cache {
        var records: [R]?
        var changeCount = -1
    }
}

private struct RecordsContextKey: EnvironmentKey {
    static let defaultValue: RecordsContext? = nil
}

extension EnvironmentValues {
    public var recordsContext: RecordsContext? {
        get { self[RecordsContextKey.self] }
        set { self[RecordsContextKey.self] = newValue }
    }
}

extension View {
    /// Makes a context available to `@Records` in this view and its children.
    public func recordsContext(_ context: RecordsContext) -> some View {
        environment(\.recordsContext, context)
    }
}
#endif
