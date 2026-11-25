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
    }

    /// Merges `theirs`, the record's new saved value, into the edit, and makes it the new
    /// `base`. A field only `theirs` changed comes in, and a field the user changed stays.
    /// A deleted record stays deleted.
    func rebase(onto theirs: Record) {
        defer { base = theirs }
        guard let ours else { return }
        let strategy = RecordMergeStrategy<Record>(favoring: .ours)
        if let base {
            state = .inserted((try? strategy.merge(base: base, ours: ours, theirs: theirs)) ?? ours)
        } else {
            // A new record that the saved value overtook: a two-way merge.
            state = .inserted((try? strategy.merge(ours: ours, theirs: theirs)) ?? ours)
        }
    }

    /// Whether a save has anything to write: a delete of a saved record, or an edit that
    /// differs from `base`, compared as JSON, since a record need not be `Equatable`. A
    /// deleted record that was never saved has nothing.
    var hasChanges: Bool {
        guard let ours else { return base != nil }
        return (try? JSONRepresentation(ours)) != base.flatMap { try? JSONRepresentation($0) }
    }
}

/// What every ``Draft`` offers, whatever its record's type.
protocol DraftProtocol: AnyObject {
    var isDeleted: Bool { get }
    var hasChanges: Bool { get }
    /// Removes the record named `recordName` from the edit's relationship lists.
    func removeReferences(to recordName: String)
}

extension Draft: DraftProtocol {
    func removeReferences(to recordName: String) {
        guard case .object(var object) = try? JSONRepresentation(ours) else { return }
        var isChanged = false
        for index in object.indices where RelationshipList.isEncoded(object[index].value) {
            guard var list = try? object[index].value.decode(RelationshipList.self),
                  list.relationships.contains(where: { $0.recordName == recordName }) else { continue }
            list.relationships.removeAll { $0.recordName == recordName }
            guard let json = try? JSONRepresentation(list) else { continue }
            object[index].value = json
            isChanged = true
        }
        // A draft that never listed the record is left alone, so its views are not woken.
        if isChanged, let edited: Record = try? JSONRepresentation.object(object).decode() { state = .inserted(edited) }
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
