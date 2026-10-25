import Foundation

/// Keeps one record current for `@Recordable`: the stored copy with the context's unsaved change laid
/// over it, read again by primary key only after a commit this tracker didn't make.
@MainActor
final class RecordTracker<R: Record> {
    /// The record as the view shows it, or its last value once it's deleted.
    private(set) var value: R
    private(set) var isDeleted = false
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
    }

    private var source: ObjectIdentifier { ObjectIdentifier(self) }

    /// Brings the value up to date with the context and returns it. `onChange` runs after each later change
    /// to the context, so the view can read again.
    func update(context: RecordContext, initial: R, zone: Zone, onChange: @escaping @MainActor () -> Void) -> R {
        if self.context !== context {
            self.context = context
            context.onChange(for: self, onChange)
        }
        let key = Key(id: initial.id, zone: zone)
        let changeCount = context.changeCount
        if self.key != key {
            // A different record or zone starts over from the record the view was given.
            value = initial
            isDeleted = false
            stored = nil
        }
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
        } else {
            isDeleted = true
        }
    }

    /// Writes an edit through the context, unless the record is deleted, the edit changes nothing, or it
    /// names another record. Returns whether it wrote.
    @discardableResult
    func write(_ record: R, context: RecordContext, zone: Zone) -> Bool {
        guard !isDeleted, record.id == value.id, !StructuralEquality.equal(record, value) else { return false }
        value = record
        context.insert(record, in: zone, source: source)
        return true
    }

    func delete(context: RecordContext, zone: Zone) {
        guard !isDeleted else { return }
        isDeleted = true
        context.delete(value, in: zone, source: source)
    }

    /// Whether edits made through this tracker are still waiting to save.
    func hasChanges(in context: RecordContext) -> Bool {
        context.hasPendingChanges(from: source)
    }
}
