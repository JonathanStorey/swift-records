#if canImport(SwiftUI)
import Foundation
import Observation
import SwiftUI

/// Keeps one record a view was given current and bindable, as `@Bindable` does for an observable object.
///
/// ```swift
/// struct ToDoDetail: View {
///     @Recordable var todo: ToDo                    // ToDoDetail(todo: todo)
///
///     var body: some View {
///         TextField("Title", text: $todo.title)
///         Toggle("Done", isOn: $todo.done)
///     }
/// }
/// ```
///
/// `$todo.title` is a `Binding<String>`, and `todo.title = "New"` writes as well. Edits go through the
/// container's `mainContext` and commit with its next save. Changes from other views, background work
/// or sync show up at once.
///
/// A record the store hasn't seen, such as `@Recordable var todo = ToDo()` in a form for a new one, is new
/// until its first edit inserts it, and `$todo.startNew()` starts another.
///
/// `@Recordable(.draft) var todo: ToDo` holds edits in the wrapper instead, for a form with Save and Cancel:
/// `$todo.save()` commits them and `$todo.rollback()` drops them. Changes from elsewhere still merge into
/// the fields the draft left alone.
///
/// It follows the context's `zone`. To pin one, initialize the wrapper in the view's initializer:
/// `_todo = Recordable(wrappedValue: todo, "pantry")`. Once the record is deleted, `todo` keeps its last
/// value and `$todo.isDeleted` turns true. After `$todo.delete()`, edits are ignored, so a late keystroke
/// can't bring it back. After a delete from elsewhere, such as another device, the edit on screen is kept:
/// `$todo.save()` brings the record back as shown, and `$todo.rollback()` or `$todo.delete()` lets the delete
/// stand. Dismiss the view on `isDeleted` to make deletes final.
@MainActor
@propertyWrapper
@dynamicMemberLookup
public struct Recordable<R: Record>: DynamicProperty {
    @Environment(\.recordContainer) private var container
    @State private var cache: Cache

    private let initial: R
    /// Makes the default value again, for `startNew()`.
    private let makeInitial: @MainActor () -> R
    private let zone: ZoneChoice
    private let animation: Animation?

    /// Tracks the record, in the context's zone unless you pass one. Changes animate with the default
    /// animation unless you pass another, or `nil` for none.
    public init(wrappedValue: @autoclosure @escaping @MainActor () -> R, _ zone: Zone? = nil, animation: Animation? = .default) {
        self.init(wrappedValue: wrappedValue(), .live, zone, animation: animation)
    }

    /// Tracks the record, holding edits as a draft until `save()` with `.draft`: `@Recordable(.draft)`.
    public init(
        wrappedValue: @autoclosure @escaping @MainActor () -> R, _ editing: RecordEditing, _ zone: Zone? = nil,
        animation: Animation? = .default
    ) {
        let initial = wrappedValue()
        self.initial = initial
        makeInitial = wrappedValue
        self.zone = ZoneChoice(zone)
        self.animation = animation
        _cache = State(initialValue: Cache(initial, editing: editing))
    }

    /// The record as the context holds it, with unsaved edits. Setting it writes through the context.
    public var wrappedValue: R {
        get { value }
        nonmutating set { Self.write(newValue, context: context, cache: cache, zone: zone) }
    }

    /// The wrapper itself, whose members bind to the record's properties: `$todo.title`.
    public var projectedValue: Recordable<R> { self }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<R, Value>) -> Binding<Value> {
        binding[dynamicMember: keyPath]
    }

    /// The whole record as a binding, for a child view that takes one.
    public var binding: Binding<R> {
        let context = context
        let cache = cache
        let initial = initial
        let choice = zone
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    Self.value(context: context, cache: cache, initial: initial, zone: choice)
                }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    Self.write(newValue, context: context, cache: cache, zone: choice)
                }
            }
        )
    }

    /// Whether the record has been deleted, here or anywhere else. When it was deleted elsewhere while the
    /// view had edits, `save()` restores it with them.
    public var isDeleted: Bool {
        _ = value
        return cache.tracker.isDeleted
    }

    /// Whether the record hasn't been inserted yet. Its first edit inserts it.
    public var isNew: Bool {
        _ = value
        return cache.tracker.isNew
    }

    /// Whether edits made through this wrapper are still waiting to save.
    public var hasChanges: Bool {
        guard let context else { return false }
        _ = value
        return cache.tracker.hasChanges(in: context)
    }

    /// Whether the sync server has the record as shown: it's saved, has no unsaved edit from this wrapper,
    /// and the server has confirmed its latest change. Without a sync provider, a saved record counts.
    public var isSynced: Bool {
        guard let context else { return false }
        _ = value
        let tracker = cache.tracker
        return !tracker.isNew && !tracker.hasChanges(in: context)
            && !context.unsynced(in: zone.zone(in: context)).contains(tracker.value.id)
    }

    /// The record as stored, when a change from elsewhere conflicted with this record's unsaved edit: a sync
    /// or another view changed a field the edit had also changed, and the edit kept its value. `nil` when
    /// there's no conflict, and once the edit saves, rolls back, or is resolved.
    ///
    /// ```swift
    /// if let other = $note.conflict {
    ///     Text("Changed on another device: \(other.title)")
    ///     Button("Use theirs") { $note.resolve(favoring: .theirs) }
    ///     Button("Keep mine") { $note.resolve(favoring: .ours) }
    /// }
    /// ```
    public var conflict: R? {
        guard let context else { return nil }
        _ = value
        return cache.tracker.conflict(context: context, zone: zone.zone(in: context))
    }

    /// Whether the unsaved edit conflicted with a change from elsewhere at this property, such as to mark the
    /// field: `$note.conflict(at: \.title)`.
    public func conflict(at keyPath: PartialKeyPath<R>) -> Bool {
        guard let context else { return false }
        _ = value
        return cache.tracker.conflict(at: keyPath, context: context, zone: zone.zone(in: context))
    }

    /// Settles the conflict: `.ours` keeps the edit's values, and `.theirs` takes the other version's at
    /// the fields in conflict. The edit stays unsaved until the context saves.
    public func resolve(favoring side: MergeSide) {
        guard let context else { return }
        cache.tracker.resolve(favoring: side, context: context, zone: zone.zone(in: context))
        withAnimation(animation) { cache.version += 1 }
    }

    /// Deletes the record when the context saves, applying its delete rules.
    public func delete() {
        guard let context else { return }
        cache.tracker.delete(context: context, zone: zone.zone(in: context))
        withAnimation(animation) { cache.version += 1 }
    }

    /// Drops the edits and delete made through this wrapper that haven't saved yet, leaving the context's
    /// other changes alone. A new record that hasn't saved goes back to new.
    public func rollback() {
        guard let context else { return }
        cache.tracker.rollback(context: context, zone: zone.zone(in: context))
        withAnimation(animation) { cache.version += 1 }
    }

    /// Starts over with a new record, the wrapper's default value made fresh, such as for "Add Another". The
    /// previous record stays as it was.
    public func startNew() {
        cache.tracker.startNew(makeInitial())
        withAnimation(animation) { cache.version += 1 }
    }

    /// Saves the context's pending changes, including this wrapper's draft.
    public func save() throws {
        guard let context else { return }
        cache.tracker.commit(context: context, zone: zone.zone(in: context))
        try context.save()
    }

    private var context: RecordContext? { mainContext(of: container) }

    private var value: R {
        cache.animation = animation
        return Self.value(context: context, cache: cache, initial: initial, zone: zone)
    }

    private static func value(context: RecordContext?, cache: Cache, initial: R, zone choice: ZoneChoice) -> R {
        // Reading the version registers the dependency. The context bumps it after each change.
        _ = cache.version
        guard let context else { return cache.tracker.value }
        return cache.tracker.update(context: context, initial: initial, zone: choice.zone(in: context)) { [weak cache] in
            guard let cache else { return }
            withAnimation(cache.animation) { cache.version += 1 }
        }
    }

    private static func write(_ record: R, context: RecordContext?, cache: Cache, zone choice: ZoneChoice) {
        guard let context else { return }
        if cache.tracker.write(record, context: context, zone: choice.zone(in: context)) {
            cache.version += 1
        }
    }

    @MainActor
    @Observable
    final class Cache {
        var version = 0
        @ObservationIgnored let tracker: RecordTracker<R>
        @ObservationIgnored var animation: Animation?

        init(_ record: R, editing: RecordEditing) {
            tracker = RecordTracker(record, editing: editing)
        }
    }
}
#endif
