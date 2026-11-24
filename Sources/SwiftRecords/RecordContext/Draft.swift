import Foundation
import Observation
import Versioning

/// A record being edited in a context and not saved yet.
///
/// `base` is the saved value the edit started from, and `ours` is the edit. When the saved
/// value changes underneath, ``rebase(onto:)`` brings the change into `ours` everywhere the
/// user did not change it. A view reads and writes `ours`, so every view on the same draft
/// sees each edit as it is made.
@Observable final class Draft<Record: Codable> {
    /// The saved value the edit started from, or `nil` for a new record.
    var base: Record?
    /// The user's edit.
    var ours: Record

    init(_ ours: Record, base: Record?) {
        self.ours = ours
        self.base = base
    }

    /// Merges `theirs`, the record's new saved value, into the edit, and makes it the new
    /// `base`. A field only `theirs` changed comes in, and a field the user changed stays.
    func rebase(onto theirs: Record) {
        let strategy = RecordMergeStrategy<Record>(favoring: .ours)
        if let base {
            ours = (try? strategy.merge(base: base, ours: ours, theirs: theirs)) ?? ours
        } else {
            // A new record that the saved value overtook: a two-way merge.
            ours = (try? strategy.merge(ours: ours, theirs: theirs)) ?? ours
        }
        base = theirs
    }

    /// Whether the edit differs from `base`, compared as JSON, since a record need not be
    /// `Equatable`.
    var hasChanges: Bool {
        (try? JSONRepresentation(ours)) != base.flatMap { try? JSONRepresentation($0) }
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
                reference.action = references.first?.action ?? reference.action
                references.append(reference)
            }
            list = try JSONRepresentation(references)
        }
        if let index { object[index].value = list } else { object.append((key, list)) }
        ours = try JSONRepresentation.object(object).decode()
    }
}
