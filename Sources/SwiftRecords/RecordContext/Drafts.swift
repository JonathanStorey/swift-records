import Foundation
import Observation
import Versioning

/// A record being edited in a context, or deleted, and not saved yet.
///
/// A context keeps one draft for each record it touches, for as long as it has it, so every
/// view holding the draft sees each change, including a delete and an insert that undoes it.
///
/// `base` is the saved value the edit started from, and ``ours`` is the edit. When the saved
/// value changes underneath, ``rebase(onto:)`` brings the change into `ours` everywhere the
/// user did not change it.
@Observable final class Draft<Record: Codable> {
    /// Whether the record is edited or deleted. A deleted record has no edit.
    enum State {
        case inserted(Record)
        case deleted
    }

    /// The saved value the edit started from, or `nil` for a new record.
    var base: Record?
    /// The edit, or deleted. Only this file sets it, so a delete always goes through
    /// ``Drafts/remove(_:at:)``, which also removes the record from other drafts' lists.
    fileprivate(set) var state: State
    /// Why the last save could not write this record, or `nil`. An edit clears it, since the
    /// edit may fix it, and so does a save that writes it.
    var error: RecordError?

    init(_ ours: Record, base: Record?) {
        state = .inserted(ours)
        self.base = base
    }

    /// The user's edit, or `nil` when the record is deleted.
    var ours: Record? {
        guard case .inserted(let record) = state else { return nil }
        return record
    }

    /// Whether the record is deleted.
    var isDeleted: Bool { ours == nil }

    /// Replaces the edit with `record`, which also undoes a delete.
    func update(_ record: Record) {
        state = .inserted(record)
        error = nil
    }

    /// Merges `theirs`, the record's new saved value, into the edit, and makes it the new
    /// `base`. A field only `theirs` changed comes in, and a field the user changed stays.
    /// A deleted record stays deleted.
    func rebase(onto theirs: Record) {
        defer { base = theirs }
        guard let ours else { return }
        let strategy = RecordMergeStrategy<Record>(favoring: .ours)
        let theirs = Self.aligned(theirs, with: ours)
        if let base {
            state = .inserted((try? strategy.merge(base: Self.aligned(base, with: ours), ours: ours, theirs: theirs)) ?? ours)
        } else {
            // A new record that the saved value overtook: a two-way merge.
            state = .inserted((try? strategy.merge(ours: ours, theirs: theirs)) ?? ours)
        }
    }

    /// Whether a save has anything to write: a delete of a saved record, or an edit that
    /// differs from `base`, compared as JSON, since a record need not be `Equatable`. A new
    /// record, or an edit that cannot be encoded, is a change. A deleted record that was
    /// never saved has nothing.
    var hasChanges: Bool {
        guard let ours else { return base != nil }
        guard let base else { return true }
        // An edit that cannot be encoded is a change, so the save reports why.
        guard let mine = try? JSONRepresentation(ours) else { return true }
        return mine != (try? JSONRepresentation(Self.aligned(base, with: ours)))
    }

    /// `saved` with an empty relationship list wherever `ours` has one and `saved` has none.
    ///
    /// A saved record with no relationships has no list in its JSON, and decodes to a list
    /// that encodes as nothing, while a record built in code encodes its empty list. Without
    /// this, an untouched record would look edited, and its empty list would win a merge
    /// over relationships saved elsewhere.
    private static func aligned(_ saved: Record, with ours: Record) -> Record {
        guard case .object(var object) = try? JSONRepresentation(saved),
              case .object(let edited) = try? JSONRepresentation(ours) else { return saved }
        let missing = edited.filter { key, json in
            RelationshipList.isEncoded(json) && (try? json.decode(RelationshipList.self))?.relationships.isEmpty == true
                && !object.contains { $0.key == key }
        }
        guard !missing.isEmpty else { return saved }
        object += missing
        return (try? JSONRepresentation.object(object).decode()) ?? saved
    }
}

/// What every ``Draft`` offers, whatever its record's type.
protocol DraftProtocol: AnyObject {
    var isDeleted: Bool { get }
    var hasChanges: Bool { get }
    var error: RecordError? { get set }
    /// Writes the draft to the row `id` of `container`, first rebasing an edit onto the row's
    /// saved value, so a change saved since `base` is merged in, not overwritten. Leaves the
    /// draft's `base` alone, since the transaction may still roll back.
    func write(to container: RecordContainer, at id: RecordContainer.RowID) throws(RecordError)
    /// Makes what was written the draft's `base`, once the save commits.
    func didSave()
    /// Throws away the unsaved change: the edit goes back to `base`, and a record never saved
    /// is deleted. The error is cleared. A draft with neither is left alone, so its views are
    /// not woken.
    func revert()
    /// Removes the record named `recordName` from the edit's relationship lists.
    func removeReferences(to recordName: String)
    /// Catches up with the row `id` of `container` after something else saved it: an edit
    /// rebases onto a new saved value, and a deleted row deletes an unchanged draft, while an
    /// edited one keeps its edit as a new record.
    func refresh(from container: RecordContainer, at id: RecordContainer.RowID)
}

extension Draft: DraftProtocol {
    func write(to container: RecordContainer, at id: RecordContainer.RowID) throws(RecordError) {
        let type = RecordContainer.recordType(of: Record.self)
        guard (try? container.registeredType(named: type)) != nil else { throw .notRegistered(type: type) }
        guard !isDeleted else {
            if base != nil { try container.delete(id, type: type) }
            return
        }
        if let saved = try? container.fetch(Record.self, id: id),
           (try? JSONRepresentation(saved)) != base.flatMap({ try? JSONRepresentation($0) }) {
            rebase(onto: saved)
        }
        guard hasChanges, let ours = self.ours else { return }
        try container.save(our: ours, at: id)
    }

    func didSave() {
        base = ours
        error = nil
    }

    func revert() {
        guard hasChanges || error != nil else { return }
        state = base.map(State.inserted) ?? .deleted
        error = nil
    }

    func removeReferences(to recordName: String) {
        removeReferences(to: recordName) { _, json in RelationshipList.isEncoded(json) }
    }

    func refresh(from container: RecordContainer, at id: RecordContainer.RowID) {
        guard let saved = try? container.fetch(Record.self, id: id) else {
            // Deleted elsewhere. A record never saved has nothing underneath to lose.
            guard base != nil else { return }
            // Losing someone's typing is worse than bringing back a deleted record.
            if !hasChanges || isDeleted { state = .deleted }
            base = nil
            return
        }
        guard (try? JSONRepresentation(saved)) != base.flatMap({ try? JSONRepresentation($0) }) else { return }
        rebase(onto: saved)
    }

    /// Removes the record named `recordName` from the list or reference under the coding key
    /// `key`: from a relationship list or a field list, or a to-one reference that points at
    /// it becomes `nil`.
    func removeReference(named recordName: String, at key: String) {
        removeReferences(to: recordName) { candidate, _ in candidate == key }
    }

    /// Removes the record named `recordName` from each list or reference `includes` picks, by
    /// its coding key and JSON, in one edit. A draft that never referenced the record is left
    /// alone, so its views are not woken.
    private func removeReferences(to recordName: String, in includes: (String, JSONRepresentation) -> Bool) {
        guard case .object(var object) = try? JSONRepresentation(ours) else { return }
        var isChanged = false
        for index in object.indices where includes(object[index].key, object[index].value) {
            guard let removed = Self.removing(recordName, from: object[index].value) else { continue }
            object[index].value = removed
            isChanged = true
        }
        if isChanged, let edited: Record = try? JSONRepresentation.object(object).decode() { state = .inserted(edited) }
    }

    /// The encoded list or reference `json` without the record named `recordName`, or `nil`
    /// when it does not name it. A to-one reference becomes `null`.
    private static func removing(_ recordName: String, from json: JSONRepresentation) -> JSONRepresentation? {
        let named = { (reference: RecordReference) in reference.recordName == recordName }
        if RelationshipList.isEncoded(json) {
            guard var list = try? json.decode(RelationshipList.self), list.relationships.contains(where: named) else { return nil }
            list.relationships.removeAll(where: named)
            return try? JSONRepresentation(list)
        }
        if case .array = json {
            guard var references = try? json.decode([RecordReference].self), references.contains(where: named) else { return nil }
            references.removeAll(where: named)
            return try? JSONRepresentation(references)
        }
        guard let reference = try? json.decode(RecordReference.self), named(reference) else { return nil }
        return .null
    }
}

/// A context's open drafts, by the row each edits.
///
/// Every change goes through it, so the rules hold together: an insert undoes a delete, and
/// a delete removes the record from every other draft's relationship lists.
struct Drafts: Collection {
    typealias Element = (key: RecordContainer.RowID, value: any DraftProtocol)
    typealias Index = [RecordContainer.RowID: any DraftProtocol].Index

    private var storage: [RecordContainer.RowID: any DraftProtocol] = [:]

    var startIndex: Index { storage.startIndex }
    var endIndex: Index { storage.endIndex }
    subscript(position: Index) -> Element { storage[position] }
    func index(after index: Index) -> Index { storage.index(after: index) }

    /// The open draft of the row `id`, deleted or not.
    func draft<Record: Codable>(_ type: Record.Type, at id: RecordContainer.RowID) -> Draft<Record>? {
        storage[id] as? Draft<Record>
    }

    /// Sets the edit of the row `id` to `record`, opening a draft on `base` when none is
    /// open, which reads `base` only then. A deleted draft is restored.
    mutating func insert<Record: Codable>(_ record: Record, at id: RecordContainer.RowID, base: () -> Record?) {
        if let draft = draft(Record.self, at: id) {
            draft.update(record)
        } else {
            storage[id] = Draft(record, base: base())
        }
    }

    /// A new draft of the row `id`, opened on its saved value.
    @discardableResult
    mutating func open<Record: Codable>(_ saved: Record, at id: RecordContainer.RowID) -> Draft<Record> {
        let draft = Draft(saved, base: saved)
        storage[id] = draft
        return draft
    }

    /// Deletes the row `id`. Its draft stays, so views holding it see the delete, and keeps
    /// its `base` for the save. Every other draft in the row's zone drops the record from its
    /// relationship lists, as its ``Relationship`` records go with it.
    mutating func remove<Record: Codable>(_ type: Record.Type, at id: RecordContainer.RowID) {
        draft(type, at: id)?.state = .deleted
        for (other, draft) in storage where other != id && other.zone == id.zone {
            draft.removeReferences(to: id.name)
        }
    }
}

// A `@References` list cannot be assigned, so a draft edits one through the edit's JSON, by
// the list's coding key.
extension Draft {
    /// The other side's property of the relationship list under the coding key `key`, as in
    /// `"Tag.notes"`, or `nil` when the list is a field list or does not say.
    func inverse(ofListAt key: String) -> String? {
        guard let json = (try? JSONRepresentation(ours))?[key], RelationshipList.isEncoded(json) else { return nil }
        return (try? json.decode(RelationshipList.self))?.inverse
    }

    /// The coding key of the relationship list whose other side is `property`, as in
    /// `"Note.tags"`, or `nil` when there is none.
    func key(ofListWithInverse property: String) -> String? {
        guard case .object(let object) = try? JSONRepresentation(ours) else { return nil }
        return object.first { RelationshipList.isEncoded($0.value) && (try? $0.value.decode(RelationshipList.self))?.inverse == property }?.key
    }

    /// Adds `reference` to the end of the list under the coding key `key`, unless the list
    /// names its record already. With an `inverse`, the list is a relationship list paired
    /// with that property. Without one, it is a field list, and the reference takes the
    /// list's action.
    func add(_ reference: RecordReference, toListAt key: String, inverse: String?) throws {
        guard case .object(var object) = try JSONRepresentation(ours) else { return }
        let index = object.firstIndex { $0.key == key }
        let json = index.map { object[$0].value }
        let list: JSONRepresentation
        if let inverse {
            var relationships = try json.map { try $0.decode(RelationshipList.self).relationships } ?? []
            if !relationships.contains(where: { $0.recordName == reference.recordName }) { relationships.append(reference) }
            list = try JSONRepresentation(RelationshipList(relationships: relationships, inverse: inverse))
        } else {
            var references = try json.map { try $0.decode([RecordReference].self) } ?? []
            if !references.contains(where: { $0.recordName == reference.recordName }) {
                var reference = reference
                reference.action = wrapper(at: key)?.action ?? references.first?.action ?? reference.action
                references.append(reference)
            }
            list = try JSONRepresentation(references)
        }
        if let index { object[index].value = list } else { object.append((key, list)) }
        state = .inserted(try JSONRepresentation.object(object).decode())
    }

    /// Points the reference under the coding key `key` at the record `reference` names. The
    /// action and whether it is a parent come from the property, or else from the reference
    /// it replaces.
    func set(_ reference: RecordReference, at key: String) throws {
        guard case .object(var object) = try JSONRepresentation(ours) else { return }
        let index = object.firstIndex { $0.key == key }
        let current = index.flatMap { try? object[$0].value.decode(RecordReference.self) }
        let wrapper = wrapper(at: key)
        var reference = reference
        if wrapper?.isParent ?? current?.isParent ?? false {
            reference = RecordReference(parent: reference.recordName, zone: reference.zone, owner: reference.owner)
        } else {
            reference.action = wrapper?.action ?? current?.action ?? reference.action
        }
        let json = try JSONRepresentation(reference)
        if let index { object[index].value = json } else { object.append((key, json)) }
        state = .inserted(try JSONRepresentation.object(object).decode())
    }

    /// The reference wrapper under the coding key `key`, found by its property's name. Its
    /// action survives here when the edit was built in code, though a nil reference or an
    /// empty list loses it in JSON.
    private func wrapper(at key: String) -> (any ReferenceAttributes)? {
        ours.flatMap { Mirror(reflecting: $0).children.first { $0.label == "_" + key }?.value as? any ReferenceAttributes }
    }
}

/// What a reference wrapper was declared with.
private protocol ReferenceAttributes {
    var action: RecordReference.Action { get }
    var isParent: Bool { get }
}

extension Reference: ReferenceAttributes {}

extension References: ReferenceAttributes {
    fileprivate var isParent: Bool { false }
}
