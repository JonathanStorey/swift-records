import Foundation
import Versioning

extension RecordContainer {
    /// The link lists of every record of type `type` in `zone`, by record name and then
    /// coding key, read from the zone's ``Relationship`` records.
    ///
    /// A link whose `keyPath` names a property of `type`, as `"Note.tags"` names `tags`,
    /// belongs to its declaring record, `references[0]`. A link whose `inverseKeyPath` names
    /// one belongs to its target, `references[1]`, as the inverse. Each list is sorted by
    /// its side's order, with unplaced links last.
    func linkLists(in zone: Zone, type: String) throws -> [String: [String: LinkList]] {
        let prefix = type + "."
        var found: [String: [String: (links: [Relationship], otherSide: String?, isInverse: Bool)]] = [:]
        for link in try fetch(Relationship.self, in: zone) where link.references.count == 2 {
            if link.keyPath.hasPrefix(prefix) {
                found[link.references[0], default: [:]][String(link.keyPath.dropFirst(prefix.count)), default: ([], link.inverseKeyPath, false)].links.append(link)
            }
            if let inverse = link.inverseKeyPath, inverse.hasPrefix(prefix) {
                found[link.references[1], default: [:]][String(inverse.dropFirst(prefix.count)), default: ([], link.keyPath, true)].links.append(link)
            }
        }
        return found.mapValues { lists in
            lists.mapValues { list in
                let name = list.isInverse ? list.links[0].references[1] : list.links[0].references[0]
                let order = { (link: Relationship) in link[orderIn: name] ?? .max }
                let sorted = list.links.sorted { (order($0), $0.id.uuidString) < (order($1), $1.id.uuidString) }
                let references = sorted.map { RecordReference(recordName: $0.target(from: name), zone: zone.name, owner: zone.owner) }
                return LinkList(links: references, otherSide: list.otherSide, isInverse: list.isInverse)
            }
        }
    }

    /// The ``Relationship`` records to save and to delete so that the record `name` of type
    /// `type` in `zone` holds `lists`, its link lists by coding key.
    ///
    /// A declaring list, as `Note.tags`, owns the links named `"Note.tags"` from the record.
    /// An inverse owns the links its declaring property names to the record. A target in a
    /// list with no link gets a new one, a link whose target left the list is deleted, and a
    /// link is saved only when it changes. Each link keeps its order when the orders still
    /// increase along the list, so removing a target renumbers nothing. Throws when an
    /// inverse does not name its declaring property.
    func linkChanges(_ lists: [(key: String, list: LinkList)], of name: String, type: String, zone: Zone) throws -> (saved: [Relationship], deleted: [Relationship]) {
        guard !lists.isEmpty else { return ([], []) }
        let all = try fetch(Relationship.self, in: zone)
        var saved: [Relationship] = [], deleted: [Relationship] = []
        for (key, list) in lists {
            let own = type + "." + key
            guard let keyPath = list.isInverse ? list.otherSide : own else {
                throw EncodingError.invalidValue(key, .init(codingPath: [], debugDescription: "The inverse list \(own) does not name the property that declares its links."))
            }
            let inverseKeyPath = list.isInverse ? own : list.otherSide
            let end = list.isInverse ? 1 : 0
            var existing: [String: Relationship] = [:]
            for link in all where link.keyPath == keyPath && link.references.count == 2 && link.references[end] == name {
                existing[link.target(from: name)] = link
            }
            var last: Int?
            for target in list.links.map(\.recordName) {
                let current = existing.removeValue(forKey: target)
                var link = current ?? Relationship(keyPath: keyPath, from: list.isInverse ? target : name, to: list.isInverse ? name : target)
                if let order = link[orderIn: name], order > last ?? .min {
                    last = order
                } else {
                    last = last.map { $0 + 1 } ?? 0
                    link[orderIn: name] = last
                }
                link.inverseKeyPath = inverseKeyPath
                if link != current { saved.append(link) }
            }
            deleted += existing.values
        }
        return (saved, deleted)
    }
}

extension JSONRepresentation {
    /// Takes the top-level link lists out of a record's JSON, by coding key.
    mutating func removeLinkLists() throws -> [(key: String, list: LinkList)] {
        guard case .object(let object) = self else { return [] }
        let lists = object.filter { LinkList.isEncoded($0.value) }
        guard !lists.isEmpty else { return [] }
        self = .object(object.filter { !LinkList.isEncoded($0.value) })
        return try lists.map { ($0.key, try $0.value.decode(LinkList.self)) }
    }

    /// The record's JSON with `lists`, its link lists by coding key, put in.
    func linking(_ lists: [String: LinkList]?) -> JSONRepresentation {
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
