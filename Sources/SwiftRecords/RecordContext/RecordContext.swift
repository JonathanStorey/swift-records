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

    /// A new context on `container`, with no edits.
    init(_ container: RecordContainer) {
        self.container = container
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

    /// Deletes `record` in ``zone``, and removes it from the relationship lists of the other
    /// records being edited, as its relationships are deleted with it.
    ///
    /// Nothing is written until `save()`. Inserting the record again undoes the delete.
    ///
    /// ```swift
    /// context.delete(note)
    /// ```
    public func delete<Record: Codable & Identifiable>(_ record: Record) where Record.ID: Encodable {
        guard let id = rowID(of: Record.self, id: record.id) else { return }
        if drafts.draft(Record.self, at: id) == nil, let saved = try? container.fetch(Record.self, id: id) {
            drafts.open(saved, at: id)
        }
        drafts.remove(Record.self, at: id)
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
        guard let rowID = rowID(of: type, id: id) else { return nil }
        if let draft = drafts.draft(type, at: rowID) { return draft.isDeleted ? nil : draft.ours }
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
    ///
    /// ```swift
    /// context.insert(tag, into: note.id, at: \Note.tags)
    /// ```
    public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parentID: Parent.ID, at keyPath: KeyPath<Parent, [Child.ID]>) where Parent.ID: Encodable, Child.ID: Codable {
        insert(child)
        guard let parent = openedDraft(Parent.self, id: parentID), let child = openedDraft(Child.self, id: child.id) else {
            assertionFailure("There is no \(Parent.self) \(parentID) in \(zone.name) to insert into.")
            return
        }
        do {
            try relate(child, to: parent, at: keyPath)
        } catch {
            assertionFailure("\(keyPath) is not a @References list: \(error)")
        }
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
    /// `parentID` at it, both in ``zone``.
    ///
    /// ```swift
    /// context.insert(folder, into: note.id, at: \Note.folder)
    /// ```
    public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parentID: Parent.ID, at keyPath: KeyPath<Parent, Child.ID?>) where Parent.ID: Encodable, Child.ID: Codable {
        insert(child)
        guard let parent = openedDraft(Parent.self, id: parentID) else {
            assertionFailure("There is no \(Parent.self) \(parentID) in \(zone.name) to insert into.")
            return
        }
        do {
            try parent.set(RecordReference(to: Child.self, id: child.id, zone: zone), at: RecordContainer.propertyName(of: keyPath).codingKey)
        } catch {
            assertionFailure("\(keyPath) is not a @Reference: \(error)")
        }
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
        try parent.add(RecordReference(to: Child.self, id: child.ours.id, zone: zone), toListAt: parentKey, inverse: childKey.map { childType + $0 })
        if let childKey {
            try child.add(RecordReference(to: Parent.self, id: parent.ours.id, zone: zone), toListAt: childKey, inverse: parentProperty)
        }
    }

    /// The row in ``zone`` for the record of type `type` with the id `id`, or `nil` when the id
    /// cannot be encoded. Its name's length is checked at save.
    func rowID<Record>(of type: Record.Type, id: some Encodable) -> RecordContainer.RowID? {
        guard let name = try? RecordContainer.recordName(for: id, type: RecordContainer.recordType(of: type), checkingLength: false) else { return nil }
        return RecordContainer.RowID(name: name, zone: zone)
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
        storedMainContext = context
        return context
    }
}
