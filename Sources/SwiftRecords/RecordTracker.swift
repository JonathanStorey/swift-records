import Foundation

/// How `@Recordable` writes edits.
public enum RecordEditing: Sendable {
    /// Each edit goes to the context at once, so other views show it and the context's next save commits it.
    case live
    /// Edits stay in the wrapper until `save()`, and `rollback()` drops them, for a form with Save and Cancel.
    /// Changes from elsewhere still merge into the fields the draft left alone.
    case draft
}

/// Keeps one record current for `@Recordable`: the stored copy with the context's unsaved change laid
/// over it, read again by primary key only after a commit this tracker didn't make. A record the store
/// has never held is new until its first edit inserts it.
@MainActor
final class RecordTracker<R: Record> {
    /// The record as the view shows it, or its last value once it's deleted.
    private(set) var value: R
    private(set) var isDeleted = false
    /// Whether the record was deleted somewhere else. The view keeps its edit, held as a draft, so saving
    /// brings the record back.
    private var deletedElsewhere = false
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
    private let editing: RecordEditing
    /// A draft's edits, which reach the context only when it commits.
    private var draft: Draft?

    private struct Draft {
        var record: R
        /// The stored fields when the draft's first edit was made, which its commit merges against.
        var base: SyncFields?
        /// The fields where the draft kept its value over a change from elsewhere.
        var clashes: Set<String> = []
    }

    struct Key: Equatable {
        let id: R.ID
        let zone: Zone
    }

    init(_ value: R, editing: RecordEditing = .live) {
        self.editing = editing
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
        let refetches = self.key != key || self.changeCount != changeCount
        let previous = stored?.first
        let wasDeleted = isDeleted
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
        if isDeleted, !wasDeleted, let previous {
            // Deleted elsewhere. An edit the user made stays as a draft with nothing to merge against, so
            // `save()` restores the record whole and a rollback lets the delete stand. Without an edit there's
            // nothing to keep, and later keystrokes are ignored.
            if draft != nil || !StructuralEquality.equal(value, previous) {
                deletedElsewhere = true
                draft = Draft(record: draft?.record ?? value, base: nil)
            }
        }
        if draft != nil {
            if refetches {
                rebaseDraft(context: context, zone: zone)
            }
            if let draft {
                value = draft.record
            }
        }
        return value
    }

    /// Merges what changed in the store since the draft began into the fields it left alone, as the context
    /// does for an unsaved edit.
    private func rebaseDraft(context: RecordContext, zone: Zone) {
        guard let base = draft?.base, let record = draft?.record,
              let (edit, newBase, clashes) = try? context.storage(for: zone).rebase(record, base: base) else { return }
        draft?.record = edit
        draft?.base = newBase
        draft?.clashes.formUnion(clashes)
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
        guard !isDeleted || deletedElsewhere, record.id == value.id, !StructuralEquality.equal(record, value) else {
            return false
        }
        value = record
        if editing == .draft || deletedElsewhere {
            if draft == nil {
                let base = isNew || deletedElsewhere ? nil : try? context.storage(for: zone).storedFields(R.self, id: record.id)
                draft = Draft(record: record, base: base)
            }
            draft?.record = record
            if let clashes = draft?.clashes, !clashes.isEmpty {
                draft?.clashes = (try? context.storage(for: zone).remainingClashes(of: record, in: clashes)) ?? clashes
            }
            return true
        }
        isNew = false
        context.insert(record, in: zone, source: source)
        return true
    }

    /// Hands a draft's edits to the context, to merge against the stored copy the draft began from.
    func commit(context: RecordContext, zone: Zone) {
        guard let draft else { return }
        self.draft = nil
        isNew = false
        isDeleted = false
        deletedElsewhere = false
        context.insert(draft.record, in: zone, source: source, base: draft.base)
    }

    /// The stored copy when an edit conflicted with a change from elsewhere.
    func conflict(context: RecordContext, zone: Zone) -> R? {
        guard editing == .draft else { return context.conflict(R.self, for: value.id, in: zone) }
        guard draft?.clashes.isEmpty == false else { return nil }
        return try? context.storage(for: zone).fetch(R.self, id: value.id)
    }

    func conflict(at keyPath: PartialKeyPath<R>, context: RecordContext, zone: Zone) -> Bool {
        guard editing == .draft else { return context.conflict(R.self, for: value.id, at: keyPath, in: zone) }
        guard let clashes = draft?.clashes, !clashes.isEmpty else { return false }
        return R.cachedSchema.fields.contains { $0.keyPath == keyPath && clashes.contains($0.name) }
    }

    func resolve(favoring side: MergeSide, context: RecordContext, zone: Zone) {
        guard editing == .draft else { return context.resolveConflict(R.self, for: value.id, favoring: side, in: zone) }
        guard var draft, !draft.clashes.isEmpty else { return }
        if side == .theirs, let stored = try? context.storage(for: zone).fetch(R.self, id: value.id) {
            for field in R.cachedSchema.fields where draft.clashes.contains(field.name) {
                _ = RecordStore.copy(field.keyPath, from: stored, into: &draft.record)
            }
        }
        draft.clashes = []
        self.draft = draft
        value = draft.record
    }

    /// Deletes the record. A new record was never inserted, so there's nothing to remove.
    func delete(context: RecordContext, zone: Zone) {
        if deletedElsewhere {
            // Lets the delete from elsewhere stand.
            draft = nil
            deletedElsewhere = false
            return
        }
        guard !isDeleted else { return }
        draft = nil
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
        draft = nil
        context.rollback(source: source)
        if deletedElsewhere {
            // The delete from elsewhere stands.
            deletedElsewhere = false
            return
        }
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
        draft != nil || context.hasPendingChanges(from: source)
    }
}
