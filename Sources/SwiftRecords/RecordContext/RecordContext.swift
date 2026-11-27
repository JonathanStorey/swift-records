import Foundation
import Observation

/// The place an app reads and edits records, as `ModelContext` is in SwiftData.
///
/// A context holds the edits not saved yet, and its ``container`` holds everything saved.
/// Views use the container's ``RecordContainer/mainContext``.
///
/// ```swift
/// let container = try RecordContainer(for: Note.self, Tag.self)
/// let context = container.mainContext
/// ```
///
/// Like `ModelContext`, a context is not `Sendable`. It stays on the actor that created it.
/// It is `@Observable`, so a view that reads through it sees records inserted and deleted.
@Observable public final class RecordContext {
    /// The container this context reads from and saves into.
    public let container: RecordContainer
    /// The open drafts, each a ``Draft`` of its record's type, by the row they edit.
    var drafts = Drafts()
    /// The zone that ``insert(_:)`` puts a new record in. An existing record keeps its own
    /// zone, so changing this never moves one.
    public var zone: Zone = "Records"
    /// Counts the container's transactions this context has applied. Reading records reads
    /// it, so a view that fetched redraws when the container changes.
    private(set) var revision = 0
    /// The task applying the container's transactions, for ``RecordContainer/mainContext``.
    @ObservationIgnored var listening: Task<Void, Never>?

    /// A new context on `container`, with no edits.
    init(_ container: RecordContainer) {
        self.container = container
    }

    deinit {
        listening?.cancel()
    }
}

extension RecordContext {
    /// Brings the context up to date with `transaction`, which its container committed. Each
    /// open draft of a record it changed catches up with the saved value, and every draft
    /// does for another process's transaction, which does not say what it changed.
    func apply(_ transaction: RecordTransaction) {
        let isExternal = transaction.author == RecordContainer.externalAuthor
        let changed = Set(transaction.changes.map(\.id))
        for (id, draft) in drafts where isExternal || changed.contains(id) {
            draft.refresh(from: container, at: id)
        }
        revision += 1
    }

    /// Applies each transaction the container commits from now on, on the main actor, until
    /// the context is released.
    @MainActor func listen() {
        guard listening == nil else { return }
        let transactions = container.transactions()
        listening = Task { @MainActor [weak self] in
            for await transaction in transactions {
                guard let self else { return }
                self.apply(transaction)
            }
        }
    }
}

extension RecordContext {
    /// Starts editing `record` in ``zone``, or replaces the edit already open for it.
    ///
    /// Nothing is written until `save()`, which is also where a record that cannot be
    /// saved throws. A record already saved keeps its saved value as the draft's base, so a
    /// save merges in whatever changed meanwhile.
    ///
    /// ```swift
    /// context.insert(Note(title: "Groceries"))
    /// ```
    public func insert<Record: Codable & Identifiable>(_ record: Record) where Record.ID: Encodable {
        let type = RecordContainer.recordType(of: Record.self)
        assert((try? container.registeredType(named: type)) != nil, "\(type) is not registered. Pass it to RecordContainer(for:).")
        guard let id = rowID(of: Record.self, id: record.id) else {
            assertionFailure("The id of \(type) \(record.id) cannot be encoded as a record name.")
            return
        }
        assert(id.name.utf8.count <= 255, "The record name \(id.name) is longer than CloudKit's 255 characters. Use a shorter id.")
        drafts.insert(record, at: id) { try? container.fetch(Record.self, id: id) }
    }

    /// Deletes `record` in ``zone``, as ``delete(_:id:)`` does by its id.
    ///
    /// ```swift
    /// context.delete(note)
    /// ```
    @discardableResult
    public func delete<Record: Codable & Identifiable>(_ record: Record) -> Record? where Record.ID: Encodable {
        delete(Record.self, id: record.id)
    }

    /// Deletes the record of type `type` with the id `id` in ``zone``, and removes it from the
    /// relationship lists of the other records being edited, as its relationships are deleted
    /// with it. Returns the record as it was, its open edit or else its saved value, or `nil`
    /// when there was nothing to delete, as `Dictionary.removeValue(forKey:)` does.
    ///
    /// Nothing is written until `save()`. Inserting the record again undoes the delete.
    ///
    /// ```swift
    /// context.delete(Note.self, id: noteID)
    /// ```
    @discardableResult
    public func delete<Record: Codable & Identifiable>(_ type: Record.Type, id: Record.ID) -> Record? where Record.ID: Encodable {
        guard let rowID = rowID(of: type, id: id) else { return nil }
        let deleted: Record?
        if let draft = drafts.draft(type, at: rowID) {
            deleted = draft.ours
        } else {
            deleted = try? container.fetch(type, id: rowID)
            if let deleted { drafts.open(deleted, at: rowID) }
        }
        // Already deleted, or never there: nothing changes.
        guard deleted != nil else { return nil }
        drafts.remove(type, at: rowID)
        return deleted
    }

    /// The record of type `type` with the id `id` in ``zone``: the edit open for it, or else
    /// its saved value, with its relationship lists filled.
    ///
    /// Returns `nil` when there is no such record, it is deleted, or its saved value does not
    /// decode as `type`, as `ModelContext.model(for:)` returns `nil` rather than throwing.
    ///
    /// ```swift
    /// let note = context.record(Note.self, id: noteID)
    /// ```
    public func record<Record: Codable & Identifiable>(_ type: Record.Type, id: Record.ID) -> Record? where Record.ID: Encodable {
        _ = revision
        guard let rowID = rowID(of: type, id: id) else { return nil }
        if let draft = drafts.draft(type, at: rowID) { return draft.ours }
        return try? container.fetch(type, id: rowID)
    }
}

extension RecordContext {
    /// Inserts `child` and adds it to the list at `keyPath` of `parent`, both in ``zone``.
    ///
    /// The parent's open edit is used, or else its saved value, so only `parent`'s id is read
    /// from the value passed. A parent with neither is inserted as `parent`, so a new parent
    /// and a new child can be made in one call. A child already in the list is not added
    /// again. For a relationship list, the child's own list lists the parent at once too.
    ///
    /// ```swift
    /// context.insert(tag, into: note, at: \.tags)
    /// ```
    public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parent: Parent, at keyPath: KeyPath<Parent, [Child.ID]>) where Parent.ID: Encodable, Child.ID: Codable {
        if openedDraft(Parent.self, id: parent.id) == nil { insert(parent) }
        insert(child, into: parent.id, at: keyPath)
    }

    /// Inserts `child` and adds it to the list at `keyPath` of the parent with the id
    /// `parentID`, both in ``zone``. The parent's open edit is used, or else its saved value.
    /// Returns the parent as it now is, or `nil`, inserting nothing, when there is no such
    /// parent, as when another device deleted it.
    ///
    /// ```swift
    /// context.insert(tag, into: note.id, at: \Note.tags)
    /// ```
    @discardableResult
    public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parentID: Parent.ID, at keyPath: KeyPath<Parent, [Child.ID]>) -> Parent? where Parent.ID: Encodable, Child.ID: Codable {
        guard let parent = openedDraft(Parent.self, id: parentID) else { return nil }
        insert(child)
        guard let child = openedDraft(Child.self, id: child.id) else { return nil }
        do {
            try relate(child, to: parent, at: keyPath)
        } catch {
            assertionFailure("\(keyPath) is not a @References list: \(error)")
        }
        return parent.ours
    }
}

extension RecordContext {
    /// Inserts `child` and points the reference at `keyPath` of `parent` at it, both in
    /// ``zone``. The parent is found as for a list, and inserted when it is new. The reference
    /// keeps its action, and whether it is a parent, from the property.
    ///
    /// ```swift
    /// context.insert(folder, into: note, at: \.folder)
    /// ```
    public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parent: Parent, at keyPath: KeyPath<Parent, Child.ID?>) where Parent.ID: Encodable, Child.ID: Codable {
        if openedDraft(Parent.self, id: parent.id) == nil { insert(parent) }
        insert(child, into: parent.id, at: keyPath)
    }

    /// Inserts `child` and points the reference at `keyPath` of the parent with the id
    /// `parentID` at it, both in ``zone``. Returns the parent as it now is, or `nil`,
    /// inserting nothing, when there is no such parent.
    ///
    /// ```swift
    /// context.insert(folder, into: note.id, at: \Note.folder)
    /// ```
    @discardableResult
    public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parentID: Parent.ID, at keyPath: KeyPath<Parent, Child.ID?>) -> Parent? where Parent.ID: Encodable, Child.ID: Codable {
        guard let parent = openedDraft(Parent.self, id: parentID) else { return nil }
        insert(child)
        do {
            try parent.set(RecordReference(to: Child.self, id: child.id, zone: zone), at: RecordContainer.propertyName(of: keyPath).codingKey)
        } catch {
            assertionFailure("\(keyPath) is not a @Reference: \(error)")
        }
        return parent.ours
    }
}

extension RecordContext {
    /// Removes `child` from the list at `keyPath` of `parent` in ``zone``, as
    /// removing by the parent's id does.
    ///
    /// ```swift
    /// context.remove(tag, from: note, at: \.tags)
    /// ```
    @discardableResult
    public func remove<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parent: Parent, at keyPath: KeyPath<Parent, [Child.ID]>) -> Parent? where Parent.ID: Encodable, Child.ID: Codable {
        remove(child, from: parent.id, at: keyPath)
    }

    /// Removes `child` from the list at `keyPath` of the parent with the id `parentID` in
    /// ``zone``. The child itself stays. For a relationship list, the parent leaves the
    /// child's own list too, so saving either side removes the relationship. Returns the
    /// parent as it now is, or `nil`, changing nothing, when there is no such parent.
    ///
    /// ```swift
    /// context.remove(tag, from: note.id, at: \Note.tags)
    /// ```
    @discardableResult
    public func remove<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parentID: Parent.ID, at keyPath: KeyPath<Parent, [Child.ID]>) -> Parent? where Parent.ID: Encodable, Child.ID: Codable {
        guard let parent = openedDraft(Parent.self, id: parentID) else { return nil }
        do {
            try unrelate(child, from: parent, at: RecordContainer.propertyName(of: keyPath))
        } catch {
            assertionFailure("\(keyPath) is not a @References list: \(error)")
        }
        return parent.ours
    }

    /// Clears the reference at `keyPath` of `parent` in ``zone`` when it points at `child`.
    ///
    /// ```swift
    /// context.remove(folder, from: note, at: \.folder)
    /// ```
    @discardableResult
    public func remove<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parent: Parent, at keyPath: KeyPath<Parent, Child.ID?>) -> Parent? where Parent.ID: Encodable, Child.ID: Codable {
        remove(child, from: parent.id, at: keyPath)
    }

    /// Clears the reference at `keyPath` of the parent with the id `parentID` in ``zone``
    /// when it points at `child`, and leaves one pointing elsewhere. Returns the parent as it
    /// now is, or `nil`, changing nothing, when there is no such parent.
    ///
    /// ```swift
    /// context.remove(folder, from: note.id, at: \Note.folder)
    /// ```
    @discardableResult
    public func remove<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parentID: Parent.ID, at keyPath: KeyPath<Parent, Child.ID?>) -> Parent? where Parent.ID: Encodable, Child.ID: Codable {
        guard let parent = openedDraft(Parent.self, id: parentID) else { return nil }
        do {
            try unrelate(child, from: parent, at: RecordContainer.propertyName(of: keyPath))
        } catch {
            assertionFailure("\(keyPath) is not a @Reference: \(error)")
        }
        return parent.ours
    }
}

private extension RecordContext {
    /// The open draft of the record of type `type` with the id `id`, or a new one opened from
    /// its saved value, or `nil` when it has neither or is deleted.
    func openedDraft<Record: Codable & Identifiable>(_ type: Record.Type, id: Record.ID) -> Draft<Record>? where Record.ID: Encodable {
        guard let rowID = rowID(of: type, id: id) else { return nil }
        if let draft = drafts.draft(type, at: rowID) { return draft.isDeleted ? nil : draft }
        guard let saved = try? container.fetch(type, id: rowID) else { return nil }
        return drafts.open(saved, at: rowID)
    }

    /// Adds `child` to the list at `keyPath` of `parent`. For a relationship list, also adds
    /// `parent` to the child's list on the other side, found from either side, since a list
    /// decoded with no relationships does not know its inverse.
    func relate<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Draft<Child>, to parent: Draft<Parent>, at keyPath: KeyPath<Parent, [Child.ID]>) throws where Parent.ID: Encodable, Child.ID: Codable {
        let parentProperty = try RecordContainer.propertyName(of: keyPath)
        let parentKey = parentProperty.codingKey
        let childType = RecordContainer.recordType(of: Child.self) + "."
        let childKey = parent.inverse(ofListAt: parentKey).flatMap { $0.hasPrefix(childType) ? String($0.dropFirst(childType.count)) : nil }
            ?? child.key(ofListWithInverse: parentProperty)
        guard let childID = child.ours?.id, let parentID = parent.ours?.id else { return }
        try parent.add(RecordReference(to: Child.self, id: childID, zone: zone), toListAt: parentKey, inverse: childKey.map { childType + $0 })
        if let childKey {
            try child.add(RecordReference(to: Parent.self, id: parentID, zone: zone), toListAt: childKey, inverse: parentProperty)
        }
    }

    /// Removes `child` from the list or reference `property` of `parent`, as in
    /// `"Album.photos"`. For a relationship list, also removes `parent` from the child's list
    /// on the other side, opening the child's draft when it is saved, so its save cannot
    /// bring the relationship back.
    func unrelate<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parent: Draft<Parent>, at property: String) throws where Parent.ID: Encodable, Child.ID: Codable {
        guard let parentID = parent.ours?.id else { return }
        let key = property.codingKey
        let childType = RecordContainer.recordType(of: Child.self)
        let inverse = parent.inverse(ofListAt: key)
        parent.removeReference(named: try RecordContainer.recordName(for: child.id, type: childType), at: key)
        guard let inverse, inverse.hasPrefix(childType + "."), let draft = openedDraft(Child.self, id: child.id) else { return }
        let parentName = try RecordContainer.recordName(for: parentID, type: RecordContainer.recordType(of: Parent.self))
        draft.removeReference(named: parentName, at: inverse.codingKey)
    }
}

extension RecordContext {
    /// The row in ``zone`` for the record of type `type` with the id `id`, or `nil` when the id
    /// cannot be encoded. Its name's length is checked at save.
    func rowID<Record>(of type: Record.Type, id: some Encodable) -> RecordContainer.RowID? {
        try? RecordContainer.RowID(type, id: id, zone: zone, checkingLength: false)
    }
}

private extension String {
    /// The coding key of a property name, `"photos"` for `"Album.photos"`.
    var codingKey: String { String(drop { $0 != "." }.dropFirst()) }
}

extension RecordContainer {
    /// The context views use, created on first use and the same one every time after.
    ///
    /// The container keeps it, and it keeps the container, so a container lives as long as
    /// the app once its main context is used, as a container normally does anyway.
    @MainActor public var mainContext: RecordContext {
        if let context = storedMainContext { return context }
        let context = RecordContext(self)
        context.listen()
        storedMainContext = context
        return context
    }
}
