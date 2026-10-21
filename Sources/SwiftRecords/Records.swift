#if canImport(SwiftUI)
import SwiftUI

/// Fetches records for a SwiftUI view and keeps them current.
///
/// ```swift
/// @Records(sort: [SortDescriptor(\.title)]) var todos: [ToDo]
///
/// List($todos, editActions: .all) { $todo in
///     TextField("Title", text: $todo.title)
/// }
/// ```
///
/// `$todos` is a real `Binding<[ToDo]>`. Writing to it inserts, updates and deletes records through
/// the environment's `RecordsContext`. Without sort descriptors, the array's order is saved too, so
/// moves persist.
@MainActor
@propertyWrapper
public struct Records<R: Record>: DynamicProperty {
    @Environment(\.recordsContext) private var context
    @State private var cache = Cache()

    private let predicate: Predicate<R>?
    private let sortDescriptors: [SortDescriptor<R>]

    public init(filter predicate: Predicate<R>? = nil, sort sortDescriptors: [SortDescriptor<R>] = []) {
        self.predicate = predicate
        self.sortDescriptors = sortDescriptors
    }

    public var wrappedValue: [R] {
        Self.records(context: context, cache: cache, predicate: predicate, sort: sortDescriptors)
    }

    public var projectedValue: Binding<[R]> {
        // Capture only Sendable values so the binding works under strict concurrency.
        let context = context
        let cache = cache
        let predicate = predicate
        let sortDescriptors = sortDescriptors
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    Self.records(context: context, cache: cache, predicate: predicate, sort: sortDescriptors)
                }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    guard let context else { return }
                    let previous = Self.records(context: context, cache: cache, predicate: predicate, sort: sortDescriptors)
                    // Show the edit immediately; the context saves it once edits pause.
                    cache.records = newValue
                    context.apply(
                        newValue, replacing: previous, keepOrder: sortDescriptors.isEmpty, source: ObjectIdentifier(cache)
                    )
                }
            }
        )
    }

    private static func records(
        context: RecordsContext?, cache: Cache, predicate: Predicate<R>?, sort: [SortDescriptor<R>]
    ) -> [R] {
        guard let context else {
            assertionFailure("@Records needs a RecordsContext. Add .recordsContext(_:) to a parent view.")
            return []
        }
        // Reading changeCount registers the dependency, so the view updates after each save.
        let changeCount = context.changeCount
        if let records = cache.records, changeCount == cache.changeCount + 1,
           context.lastSaveSource == ObjectIdentifier(cache) {
            // The save only wrote this view's own edits, which the cache already shows. Filter and sort
            // in memory so an edited record still leaves or moves, without reading the database again.
            var updated = records
            if let predicate {
                updated = (try? updated.filter { try predicate.evaluate($0) }) ?? updated
            }
            if !sort.isEmpty {
                updated.sort(using: sort)
            }
            cache.records = updated
            cache.changeCount = changeCount
        } else if cache.changeCount != changeCount || cache.records == nil {
            cache.records = (try? context.container.fetch(R.self, where: predicate, sortBy: sort)) ?? []
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
