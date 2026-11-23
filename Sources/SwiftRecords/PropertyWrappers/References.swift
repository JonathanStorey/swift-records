import Foundation
import Versioning

/// A read-only to-many relationship, holding the targets' ``RecordID``s in order.
///
/// The initializer picks how the list is stored, and the property reads the
/// same either way:
///
/// ```swift
/// struct Note: Codable, Identifiable {
///     var id: UUID
///     @References var attachments: [RecordID<Attachment>] = []    // a field on the record
///     @References(to: \Tag.notes) var tags: [RecordID<Tag>] = []  // Relationship records
/// }
///
/// struct Tag: Codable, Identifiable {
///     var id: UUID
///     @References(from: \Note.tags) var notes: [RecordID<Note>] = []   // the inverse
/// }
/// ```
///
/// No key path stores the list as one reference list field, like
/// `CKRecord`'s own. It travels with the record, and two devices settle on
/// one list.
///
/// A key path to the target's inverse stores each reference as its own
/// ``Relationship`` record, so the list has no size limit and edits from two
/// devices merge. The key path is a signal, not a name: the link is named
/// by the declaring side, as in `"Note.tags"`, from the coding key it
/// encodes. The inverse points back at the declaring property and reads the
/// same links from the other end. Its link name comes from the coding key
/// behind the key path, so it follows `CodingKeys` and works on every
/// platform.
///
/// The property is set when the model is created or decoded and cannot be
/// assigned afterwards. Either way it encodes each id as a
/// ``RecordReference`` carrying the action. An empty list is
/// left out of a keyed container, and a missing key decodes as an empty
/// list.
///
/// The action follows `CKRecord.Reference`: with `.deleteSelf`, the record
/// holding the property deletes itself when any target is deleted. Swift
/// does not pass the attribute's arguments to `init(from:)`, so a decoded
/// list takes the action of its first element, an empty list decodes with
/// `.none`, and a decoded list's ``storage`` is `nil`. Equality and hashing compare the ids and the action only.
@propertyWrapper
public struct References<Target>: Sendable {
    public let wrappedValue: [RecordID<Target>]
    public let action: RecordReference.Action

    /// How the list is stored, or `nil` when the wrapper was decoded,
    /// because Swift does not pass the attribute's arguments to
    /// `init(from:)`.
    public let storage: Storage?

    /// Finds an inverse's link name. Only the inverse initializer sets it,
    /// because only it knows the declaring type is `Decodable`.
    private let inverseName: (@Sendable () throws -> String)?

    /// Where a list's references are stored.
    public enum Storage: Hashable, Sendable {
        /// One reference list field on the record.
        case field
        /// ``Relationship`` records named by this side.
        case links
        /// ``Relationship`` records named by the declaring property.
        case inverse
    }

    /// The links an inverse reads, as in `"Note.tags"`, or `nil` when the
    /// list is not an inverse. It decodes a placeholder of the declaring
    /// type on each call, so store it when you need it repeatedly.
    public var inverse: String? {
        get throws { try inverseName?() }
    }

    fileprivate init(wrappedValue: [RecordID<Target>], action: RecordReference.Action, storage: Storage?, inverseName: (@Sendable () throws -> String)? = nil) {
        self.wrappedValue = wrappedValue
        self.action = action
        self.storage = storage
        self.inverseName = inverseName
    }

    /// A list stored as one reference list field on the record.
    public init(wrappedValue: [RecordID<Target>] = [], action: RecordReference.Action = .none) {
        self.init(wrappedValue: wrappedValue, action: action, storage: .field)
    }

    /// A list stored as ``Relationship`` records, declared on this side.
    /// `inverse` is the target's property that reads the same links back,
    /// and its root is the target type.
    public init<Source>(wrappedValue: [RecordID<Target>] = [], to inverse: KeyPath<Target, [RecordID<Source>]>, action: RecordReference.Action = .none) {
        self.init(wrappedValue: wrappedValue, action: action, storage: .links)
    }

    /// The inverse of the list at `declaringProperty`, reading the same
    /// ``Relationship`` records from the other side.
    public init<Source>(wrappedValue: [RecordID<Target>] = [], from declaringProperty: KeyPath<Target, [RecordID<Source>]> & Sendable, action: RecordReference.Action = .none) where Target: Decodable {
        self.init(wrappedValue: wrappedValue, action: action, storage: .inverse, inverseName: { try Self.linkName(of: declaringProperty) })
    }
}

private extension References {
    /// The link name of a reference list, `"Root.key"`, from a key path to
    /// it, such as `"Note.tags"` for `\Note.tags`.
    ///
    /// The key is the coding key `Root` decodes the property from, found by
    /// reading the key path on a placeholder `Root` whose references each
    /// have a unique record name. It needs no runtime names, so it works in
    /// stripped builds and on Linux.
    static func linkName<Root: Decodable, Element>(of keyPath: KeyPath<Root, [RecordID<Element>]>) throws -> String {
        let recorded = try JSONSchema.placeholder(for: Root.self)
        guard let marker = recorded.value[keyPath: keyPath].first.flatMap({ UUID(uuidString: $0.name) }), let key = recorded.markers[marker]?.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The key path does not lead to a reference list that \(Root.self) decodes."))
        }
        return "\(Root.self).\(key)"
    }
}

extension References: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.wrappedValue, lhs.action) == (rhs.wrappedValue, rhs.action)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(wrappedValue)
        hasher.combine(action)
    }
}

extension References {
    /// The other ends of the links to the record `source`, in its zone, sorted by its
    /// side's order, `order` when it declares them and `inverseOrder` when
    /// it is an inverse, with unplaced links last.
    public init<Source>(_ links: [Relationship], from source: RecordID<Source>, action: RecordReference.Action = .none) {
        let order = { (link: Relationship) in link[orderIn: source.name] ?? .max }
        let sorted = links.sorted { (order($0), $0.id.uuidString) < (order($1), $1.id.uuidString) }
        let targets = sorted.map { RecordID<Target>(name: $0.target(from: source.name), zone: source.zone) }
        self.init(wrappedValue: targets, action: action, storage: nil)
    }
}

extension References: Mergeable {
    /// The ids merged element by element, so ids each side added are both
    /// kept, in place, and an id one side removed is removed. The action is
    /// the side that changed it, and how the list is stored is this
    /// version's.
    public func merging(with theirs: References, from base: References) throws(MergeConflict) -> References {
        let ids = try RangeReplaceableCollectionElementMerge<[RecordID<Target>]>().merge(base: base.wrappedValue, ours: wrappedValue, theirs: theirs.wrappedValue)
        return References(wrappedValue: ids, action: action == base.action ? theirs.action : action, storage: storage, inverseName: inverseName)
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
        let references = try container.decode([RecordReference].self)
        let ids = try references.map { try RecordID<Target>($0, in: container) }
        self.init(wrappedValue: ids, action: references.first?.action ?? .none, storage: nil)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.map { $0.reference(action: action) })
    }
}

extension KeyedDecodingContainer {
    public func decode<Target>(_ type: References<Target>.Type, forKey key: Key) throws -> References<Target> {
        try decodeIfPresent(type, forKey: key) ?? References(wrappedValue: [], action: .none, storage: nil)
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<Target>(_ value: References<Target>, forKey key: Key) throws {
        guard !value.wrappedValue.isEmpty else { return }
        try encodeIfPresent(Optional(value), forKey: key)
    }
}
