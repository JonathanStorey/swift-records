import Foundation
import Versioning

/// A read-only to-many relationship, holding the targets' own ids in order.
///
/// The initializer picks how the list is stored, and the property reads the same either
/// way:
///
/// ```swift
/// struct Note: Codable, Identifiable {
///     var id: UUID
///     @References<Attachment> var attachments: [Attachment.ID] = []       // a field on the record
///     @References<Tag>(to: \Tag.notes) var tags: [Tag.ID] = []            // Relationship records
/// }
///
/// struct Tag: Codable, Identifiable {
///     var id: UUID
///     @References<Note>(from: \Note.tags) var notes: [Note.ID] = []       // the inverse
/// }
/// ```
///
/// No key path stores the list as one reference list field, like `CKRecord`'s own. It
/// travels with the record, and two devices settle on one list.
///
/// A key path to the target's inverse stores each reference as its own ``Relationship``
/// record, so the list has no size limit and edits from two devices merge. The link is
/// named by the declaring side, as in `"Note.tags"`, from the coding key it encodes, and
/// the inverse reads the same links from the other end. The container writes the links
/// when it saves the record and reads them back when it fetches it, so the record itself
/// never holds them.
///
/// Every target lives in the holding record's zone, as CloudKit requires. ``zone`` is `nil`
/// for a value built in code, and the container fills it in when it saves the record. The
/// projected value is the wrapper itself, which carries the targets' type, ids and zone
/// together.
///
/// The property is set when the model is created or decoded and cannot be assigned
/// afterwards. A field list encodes each id as a ``RecordReference`` carrying the action.
/// An empty field list is left out of a keyed container, and a missing key decodes as an
/// empty list.
///
/// The action follows `CKRecord.Reference`: with `.deleteSelf`, the record holding the
/// property deletes itself when any target is deleted. Swift does not pass the attribute's
/// arguments to `init(from:)`, so a decoded list takes the action of its first element, and
/// an empty list decodes with `.none`. Equality and hashing compare the ids, the action and
/// the zone.
@propertyWrapper
public struct References<Target: Identifiable>: Sendable where Target.ID: Codable & Sendable {
    public let wrappedValue: [Target.ID]
    public let action: RecordReference.Action
    /// The zone the targets live in, the holding record's, or `nil` until the record is saved.
    public let zone: Zone?

    /// How the list is stored, or `nil` when it was decoded from a missing key, which
    /// cannot tell.
    public let storage: Storage?

    /// The link name of the other side, as in `"Tag.notes"` for `Note.tags`, or `nil` for a
    /// field list. A list built in code finds it from its key path when it is encoded.
    private let otherSide: (@Sendable () throws -> String)?

    /// Where a list's references are stored.
    public enum Storage: Hashable, Sendable {
        /// One reference list field on the record.
        case field
        /// ``Relationship`` records named by this side.
        case links
        /// ``Relationship`` records named by the declaring property.
        case inverse
    }

    /// The list itself, with the targets' type, ids and zone.
    public var projectedValue: Self { self }

    fileprivate init(_ ids: [Target.ID], action: RecordReference.Action, zone: Zone?, storage: Storage?, otherSide: (@Sendable () throws -> String)? = nil) {
        wrappedValue = ids
        self.action = action
        self.zone = zone
        self.storage = storage
        self.otherSide = otherSide
    }

    /// A list stored as one reference list field on the record.
    public init(wrappedValue: [Target.ID] = [], action: RecordReference.Action = .none) {
        self.init(wrappedValue, action: action, zone: nil, storage: .field)
    }

    /// A list stored as ``Relationship`` records, declared on this side. `inverse` is the
    /// target's property that reads the same links back.
    public init<SourceID: Codable & Hashable>(wrappedValue: [Target.ID] = [], to inverse: KeyPath<Target, [SourceID]> & Sendable, action: RecordReference.Action = .none) where Target: Decodable {
        self.init(wrappedValue, action: action, zone: nil, storage: .links, otherSide: { try Self.linkName(of: inverse) })
    }

    /// The inverse of the list at `declaringProperty`, reading the same ``Relationship``
    /// records from the other side.
    public init<SourceID: Codable & Hashable>(wrappedValue: [Target.ID] = [], from declaringProperty: KeyPath<Target, [SourceID]> & Sendable, action: RecordReference.Action = .none) where Target: Decodable {
        self.init(wrappedValue, action: action, zone: nil, storage: .inverse, otherSide: { try Self.linkName(of: declaringProperty) })
    }
}

/// How a list stored as ``Relationship`` records encodes: its targets and the other side's
/// link name, never stored on the record. The container takes it out of a record it saves
/// and puts it in for a record it fetches. The keys start with `$` so no model's own
/// property reads as one.
struct LinkList: Codable, Hashable {
    /// The targets, in order.
    var links: [RecordReference]
    /// The other side's link name, as in `"Tag.notes"`.
    var otherSide: String?
    /// Whether this side is the inverse, reading links named by the other side.
    var isInverse: Bool

    private enum CodingKeys: String, CodingKey {
        case links = "$links", otherSide = "$otherSide", isInverse = "$isInverse"
    }

    /// Whether `json` is an encoded link list.
    static func isEncoded(_ json: JSONRepresentation) -> Bool {
        json[CodingKeys.links.rawValue] != nil
    }
}

extension References {
    /// The link name of a reference list, `"Root.key"`, from a key path to it, such as
    /// `"Note.tags"` for `\Note.tags`.
    ///
    /// The key is the coding key `Root` decodes the property from, found by reading the key
    /// path on a placeholder `Root` whose lists each hold one unique marker id. It needs no
    /// runtime names, so it works in stripped builds and on Linux.
    fileprivate static func linkName<Root: Decodable, ID: Decodable & Hashable>(of keyPath: KeyPath<Root, [ID]>) throws -> String {
        let recorded = try JSONSchema.placeholder(for: Root.self)
        guard let marked = recorded.value[keyPath: keyPath].first,
              let key = recorded.markers.first(where: { ID.marked($0.key) == marked })?.value.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The key path does not lead to a reference list that \(Root.self) decodes, or \(ID.self) is not an id that encodes as a JSON string or number."))
        }
        return "\(RecordContainer.recordType(of: Root.self)).\(key)"
    }
}

// The schema placeholder gives each list one unique marker id, so a key path to it can be
// traced back to its coding key.
extension References: JSONSchema.Markable {
    public mutating func mark(_ marker: UUID) {
        guard let id = Target.ID.marked(marker) else { return }
        self = References([id], action: action, zone: zone, storage: storage)
    }
}

private extension Decodable {
    /// An id of this type made from `marker`, decoded from a record name as an id is: the
    /// marker itself, its text, or a number from its first six bytes. `nil` for an id that
    /// encodes as neither a JSON string nor a number.
    static func marked(_ marker: UUID) -> Self? {
        let bytes = withUnsafeBytes(of: marker.uuid) { Array($0.prefix(6)) }
        let number = bytes.reduce(0) { $0 << 8 | Int($1) }
        return [marker.uuidString, "Marker:" + marker.uuidString, "Marker:\(number)"]
            .lazy.compactMap { RecordContainer.id(Self.self, fromRecordName: $0) }.first
    }
}

extension References: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.wrappedValue, lhs.action, lhs.zone) == (rhs.wrappedValue, rhs.action, rhs.zone)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(wrappedValue)
        hasher.combine(action)
        hasher.combine(zone)
    }
}

extension References: Mergeable {
    /// The ids merged element by element, so ids each side added are both kept, in place,
    /// and an id one side removed is removed. The action is the side that changed it, and
    /// how the list is stored is this version's.
    public func merging(with theirs: References, from base: References) throws(MergeConflict) -> References {
        let ids = try RangeReplaceableCollectionElementMerge<[Target.ID]>().merge(base: base.wrappedValue, ours: wrappedValue, theirs: theirs.wrappedValue)
        return References(ids, action: action == base.action ? theirs.action : action, zone: zone ?? theirs.zone, storage: storage, otherSide: otherSide)
    }

    /// Without a base, equal lists merge, and any others conflict.
    public func merging(with theirs: References) throws(MergeConflict) -> References {
        guard self == theirs else { throw MergeConflict() }
        return self
    }
}

extension References: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let references: [RecordReference], storage: Storage, otherSide: String?
        if let field = try? container.decode([RecordReference].self) {
            (references, storage, otherSide) = (field, .field, nil)
        } else {
            let list = try container.decode(LinkList.self)
            (references, storage, otherSide) = (list.links, list.isInverse ? .inverse : .links, list.otherSide)
        }
        // A schema placeholder's reference has an empty name, which no record has.
        let named = references.filter { !$0.recordName.isEmpty }
        let ids = try named.map { try Target.ID($0, in: container) }
        self.init(ids, action: named.first?.action ?? .none, zone: named.first?.placedZone, storage: storage, otherSide: otherSide.map { name in { @Sendable in name } })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let references = try wrappedValue.map { try RecordReference(to: Target.self, id: $0, zone: zone, action: action) }
        switch storage {
        case .links, .inverse: try container.encode(LinkList(links: references, otherSide: otherSide?(), isInverse: storage == .inverse))
        case .field, nil: try container.encode(references)
        }
    }
}

extension KeyedDecodingContainer {
    public func decode<Target>(_ type: References<Target>.Type, forKey key: Key) throws -> References<Target> {
        try decodeIfPresent(type, forKey: key) ?? References([], action: .none, zone: nil, storage: nil)
    }
}

extension KeyedEncodingContainer {
    /// Leaves out an empty field list. A list stored as links is always encoded, so the
    /// container sees an emptied list and removes its links.
    public mutating func encode<Target>(_ value: References<Target>, forKey key: Key) throws {
        guard !value.wrappedValue.isEmpty || value.storage == .links || value.storage == .inverse else { return }
        try encodeIfPresent(Optional(value), forKey: key)
    }
}
