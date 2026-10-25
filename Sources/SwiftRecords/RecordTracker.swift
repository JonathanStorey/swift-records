import Foundation

/// Keeps one record current for `@Recordable`: the stored copy with the context's unsaved change laid
/// over it, read again by primary key only after a commit this tracker didn't make. A record the store
/// has never held is new until its first edit inserts it.
@MainActor
final class RecordTracker<R: Record> {
    /// The record as the view shows it, or its last value once it's deleted.
    private(set) var value: R
    private(set) var isDeleted = false
    /// Whether the record hasn't been inserted yet, here or anywhere else.
    private(set) var isNew = true
    /// The record when tracking began, which a rollback of a new record returns to.
    private var original: R
    /// The view's default value last time, so a new record handed in again doesn't replace this one.
    private var lastInitialID: R.ID
    /// The record as fetched, empty when the store has none.
    private var stored: [R]?
    private var key: Key?
    private var changeCount = -1
    /// The context's last change number this tracker has seen.
    private var sequence = 0
    private weak var context: RecordContext?

    struct Key: Equatable {
        let id: R.ID
        let zone: Zone
    }

    init(_ value: R) {
        self.value = value
        original = value
        lastInitialID = value.id
    }

    private var source: ObjectIdentifier { ObjectIdentifier(self) }

    /// Brings the value up to date with the context and returns it. `onChange` runs after each later change
    /// to the context, so the view can read again.
    func update(context: RecordContext, initial: R, zone: Zone, onChange: @escaping @MainActor () -> Void) -> R {
        if self.context !== context {
            self.context = context
            context.onChange(for: self, onChange)
        }
        if initial.id != lastInitialID, initial.id != value.id, exists(initial.id, in: zone, context: context) {
            // The view was handed another record. A new one, such as a default value made again on each
            // render, doesn't replace the record this tracker holds.
            value = initial
            original = initial
            isNew = true
            isDeleted = false
            stored = nil
            self.key = nil
        }
        lastInitialID = initial.id
        let key = Key(id: value.id, zone: zone)
        let changeCount = context.changeCount
        if self.key == key, changeCount == self.changeCount + 1, context.lastSaveSource == source {
            // The save only wrote this tracker's own edit, which the value already shows.
            stored = isDeleted ? [] : [value]
            self.changeCount = changeCount
        } else if self.key != key || self.changeCount != changeCount {
            // If the fetch fails, such as while another process holds the file, the view keeps what it
            // showed rather than call the record deleted.
            do {
                stored = try context.storage(for: zone).fetch(R.self, id: key.id).map { [$0] } ?? []
            } catch {}
            self.changeCount = changeCount
            self.key = key
            overlay(context, zone: zone)
        } else if context.sequence != sequence, context.hasPendingChanges(after: sequence, excluding: source) {
            // Other code changed records without saving yet.
            overlay(context, zone: zone)
        }
        sequence = context.sequence
        return value
    }

    private func overlay(_ context: RecordContext, zone: Zone) {
        guard let stored, let key else { return }
        if let record = context.overlay(stored, in: zone, includes: { $0.id == key.id }).first {
            value = record
            isDeleted = false
            isNew = false
        } else if !isNew {
            isDeleted = true
        }
    }

    private func exists(_ id: R.ID, in zone: Zone, context: RecordContext) -> Bool {
        let stored = (try? context.storage(for: zone).fetch(R.self, id: id)).map { [$0] } ?? []
        return !context.overlay(stored, in: zone, includes: { $0.id == id }).isEmpty
    }

    /// Writes an edit through the context, inserting a new record, unless the record is deleted, the edit
    /// changes nothing, or it names another record. Returns whether it wrote.
    @discardableResult
    func write(_ record: R, context: RecordContext, zone: Zone) -> Bool {
        guard !isDeleted, record.id == value.id, !StructuralEquality.equal(record, value) else { return false }
        value = record
        isNew = false
        context.insert(record, in: zone, source: source)
        return true
    }

    /// Deletes the record. A new record was never inserted, so there's nothing to remove.
    func delete(context: RecordContext, zone: Zone) {
        guard !isDeleted else { return }
        isDeleted = true
        if !isNew {
            context.delete(value, in: zone, source: source)
        }
    }

    /// Starts over with `record`, as a new record unless the store already holds it, leaving the previous
    /// record as it is.
    func startNew(_ record: R) {
        value = record
        original = record
        isNew = true
        isDeleted = false
        stored = nil
        key = nil
    }

    /// Drops this tracker's unsaved edits and delete. A new record that hasn't saved goes back to new.
    func rollback(context: RecordContext, zone: Zone) {
        context.rollback(source: source)
        if (try? context.storage(for: zone).fetch(R.self, id: value.id)) == nil {
            value = original
            isNew = true
        }
        isDeleted = false
        stored = nil
        key = nil
    }

    /// Whether edits made through this tracker are still waiting to save.
    func hasChanges(in context: RecordContext) -> Bool {
        context.hasPendingChanges(from: source)
    }
}
