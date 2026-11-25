import Foundation

/// Why ``RecordContext/save()`` did not write everything.
public enum SaveError: Error, Equatable {
    /// SQLite failed, so nothing was written, and every draft is as it was.
    case database(DatabaseError)
    /// Every other change was written. These records were not, each by its record name, as
    /// in `"Note:intro"`, with why. Each one's draft stays open with its ``RecordError``.
    case unsaved([String: RecordError])
}

extension RecordContext {
    /// Writes every change made in this context to the container, in one transaction.
    ///
    /// Each edit is first rebased onto the record's current saved value, so a change saved
    /// since the edit began, such as a relationship another device added, is merged in
    /// rather than overwritten. A record that cannot be written does not stop the others:
    /// it keeps its draft and its error, which ``error(_:id:)`` reads, and the save throws
    /// ``SaveError/unsaved(_:)`` once the rest are written. A database failure writes nothing
    /// and throws ``SaveError/database(_:)``.
    ///
    /// ```swift
    /// do {
    ///     try context.save()
    /// } catch .unsaved(let errors) {
    ///     // Show each error on its record.
    /// }
    /// ```
    public func save() throws(SaveError) {
        let changed = drafts.filter { $0.value.hasChanges }
        guard !changed.isEmpty else { return }
        var written: [any DraftProtocol] = [], failures: [String: RecordError] = [:]
        do throws(DatabaseError) {
            try container.transaction { () throws(DatabaseError) in
                for (id, draft) in changed {
                    do throws(RecordError) {
                        try draft.write(to: container, at: id)
                        written.append(draft)
                    } catch {
                        guard case .database(let error) = error else {
                            failures[id.name] = error
                            continue
                        }
                        throw error
                    }
                }
            }
        } catch {
            throw .database(error)
        }
        for draft in written { draft.didSave() }
        for (id, draft) in changed { if let error = failures[id.name] { draft.error = error } }
        if !failures.isEmpty { throw .unsaved(failures) }
    }

    /// Throws away every change not saved, as `ModelContext.rollback()` does.
    ///
    /// Each edit goes back to the record's saved value, a deleted record comes back, and a
    /// record never saved is deleted. Save errors are cleared. The drafts themselves stay, so
    /// every view holding one sees it reset.
    ///
    /// ```swift
    /// context.rollback()
    /// ```
    public func rollback() {
        for (_, draft) in drafts { draft.revert() }
    }

    /// Why the last ``save()`` could not write the record of type `type` with the id `id` in
    /// ``zone``, or `nil` when it was written, or has not been saved since it changed.
    public func error<Record: Codable & Identifiable>(_ type: Record.Type, id: Record.ID) -> RecordError? where Record.ID: Encodable {
        guard let rowID = rowID(of: type, id: id) else { return nil }
        return drafts.draft(type, at: rowID)?.error
    }
}
