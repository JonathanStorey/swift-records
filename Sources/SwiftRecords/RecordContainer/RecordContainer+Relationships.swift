import Foundation
import Versioning

extension RecordContainer {
    /// The relationship lists of every record of type `type` in `zone`, by record name and
    /// then coding key, read from the zone's ``Relationship`` records.
    ///
    /// Each side of a relationship whose property belongs to `type`, as `"Note.tags"` belongs
    /// to `Note`, puts the other side's record in that side's list. Each list is sorted by
    /// its side's order, with unplaced relationships last. A record related to itself
    /// through one symmetric property is listed once.
    func relationshipLists(in zone: Zone, type: String) throws -> [String: [String: RelationshipList]] {
        let prefix = type + "."
        var found: [String: [String: (inverse: String, targets: [(name: String, order: Int?, id: String)])]] = [:]
        for relationship in try fetch(Relationship.self, in: zone) where relationship.isWellFormed {
            let (keyPaths, references) = (relationship.keyPaths, relationship.references)
            for side in [0, 1] where keyPaths[side].hasPrefix(prefix) {
                if side == 1, keyPaths[0] == keyPaths[1], references[0] == references[1] { continue }
                let other = 1 - side
                let target = (references[other], relationship.orders[side], relationship.id)
                found[references[side], default: [:]][String(keyPaths[side].dropFirst(prefix.count)), default: (keyPaths[other], [])].targets.append(target)
            }
        }
        return found.mapValues { lists in
            lists.mapValues { list in
                let sorted = list.targets.sorted { ($0.order ?? .max, $0.id) < ($1.order ?? .max, $1.id) }
                let references = sorted.map { RecordReference(recordName: $0.name, zone: zone.name, owner: zone.owner) }
                return RelationshipList(relationships: references, inverse: list.inverse)
            }
        }
    }

    /// The ``Relationship`` records to save and to delete so that the record `name` of type
    /// `type` in `zone` holds `lists`, its relationship lists by coding key.
    ///
    /// A list owns the relationships with a side that is the record in its property, paired
    /// with the list's inverse. A target with no relationship gets a new one, a relationship
    /// whose target left the list is deleted, and a relationship is saved only when it
    /// changes. Each keeps its order when the orders still increase along the list, so
    /// removing a target renumbers nothing.
    ///
    /// Throws when a list does not name its inverse, or when the record's property or a new
    /// target's inverse already has relationships paired with another property, which means
    /// the two sides' key paths do not point at each other.
    func relationshipChanges(_ lists: [(key: String, list: RelationshipList)], of name: String, type: String, zone: Zone) throws -> (saved: [Relationship], deleted: [Relationship]) {
        guard !lists.isEmpty else { return ([], []) }
        let all = try fetch(Relationship.self, in: zone).filter(\.isWellFormed)
        var saved: [Relationship] = [], deleted: [Relationship] = []
        for (key, list) in lists {
            let keyPath = type + "." + key
            guard let inverse = list.inverse else {
                throw EncodingError.invalidValue(key, .init(codingPath: [], debugDescription: "The relationship list \(keyPath) does not name its inverse."))
            }
            var existing: [String: Relationship] = [:]
            for relationship in all {
                guard let side = relationship.side(of: name, keyPath: keyPath) else { continue }
                let paired = relationship.keyPaths[1 - side]
                guard paired == inverse else {
                    throw EncodingError.invalidValue(key, .init(codingPath: [], debugDescription: "\(keyPath) names \(inverse) as its inverse, but it already has relationships with \(paired). The two key paths must point at each other."))
                }
                existing[relationship.target(from: name, keyPath: keyPath)] = relationship
            }
            var last: Int?
            for target in list.relationships.map(\.recordName) {
                let current = existing.removeValue(forKey: target)
                if current == nil, let paired = Self.pairing(of: target, in: inverse, among: all), paired != keyPath {
                    throw EncodingError.invalidValue(key, .init(codingPath: [], debugDescription: "\(keyPath) names \(inverse) as its inverse, but \(inverse) already has relationships with \(paired). The two key paths must point at each other."))
                }
                var relationship = current ?? Relationship(between: (keyPath, name), and: (inverse, target))
                if let order = relationship[orderIn: name, keyPath: keyPath], order > last ?? .min {
                    last = order
                } else {
                    last = last.map { $0 + 1 } ?? 0
                    relationship[orderIn: name, keyPath: keyPath] = last
                }
                if relationship != current { saved.append(relationship) }
            }
            deleted += existing.values
        }
        return (saved, deleted)
    }

    /// The property that the property `keyPath` of the record `name` is already paired with
    /// in `relationships`, or `nil` when it has none.
    private static func pairing(of name: String, in keyPath: String, among relationships: [Relationship]) -> String? {
        relationships.lazy.compactMap { relationship in
            relationship.side(of: name, keyPath: keyPath).map { relationship.keyPaths[1 - $0] }
        }.first
    }

    /// Every ``Relationship`` in `zone` with a side that is the record `name` of type `type`.
    func relationships(of name: String, type: String, in zone: Zone) throws -> [Relationship] {
        try fetch(Relationship.self, in: zone).filter { relationship in
            relationship.isWellFormed && [0, 1].contains { relationship.references[$0] == name && relationship.keyPaths[$0].hasPrefix(type + ".") }
        }
    }
}

extension JSONRepresentation {
    /// Takes the top-level relationship lists out of a record's JSON, by coding key.
    mutating func removeRelationshipLists() throws -> [(key: String, list: RelationshipList)] {
        guard case .object(let object) = self else { return [] }
        let lists = object.filter { RelationshipList.isEncoded($0.value) }
        guard !lists.isEmpty else { return [] }
        self = .object(object.filter { !RelationshipList.isEncoded($0.value) })
        return try lists.map { ($0.key, try $0.value.decode(RelationshipList.self)) }
    }

    /// The record's JSON with `lists`, its relationship lists by coding key, put in.
    func relating(_ lists: [String: RelationshipList]?) -> JSONRepresentation {
        guard let lists, case .object(var object) = self else { return self }
        for (key, list) in lists {
            guard let json = try? JSONRepresentation(list) else { continue }
            object.removeAll { $0.key == key }
            object.append((key, json))
        }
        return .object(object)
    }

    /// The JSON with each ``RecordReference`` placed in `zone`: one with no zone takes it,
    /// and one in another zone throws, since CloudKit follows a reference only within its
    /// record's zone. A reference is any object with a `recordName` and an `action`.
    func placingReferences(in zone: Zone) throws -> JSONRepresentation {
        switch self {
        case .array(let array):
            return .array(try array.map { try $0.placingReferences(in: zone) })
        case .object(var object):
            if self["recordName"] != nil, self["action"] != nil {
                switch (self["zone"], self["owner"] ?? .string(Zone.defaultOwner)) {
                case (nil, _):
                    object.removeAll { $0.key == "owner" }
                    object += [("zone", .string(zone.name)), ("owner", .string(zone.owner))]
                case (.string(zone.name)?, .string(zone.owner)):
                    break
                default:
                    throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "A reference points into another zone than \(zone.name). CloudKit follows a reference only within its record's zone."))
                }
                return .object(object)
            }
            return .object(try object.map { ($0.key, try $0.value.placingReferences(in: zone)) })
        default:
            return self
        }
    }
}
