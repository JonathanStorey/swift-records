import Foundation

/// A read-only reference to another record in the same zone, held as the target's own id.
///
/// ```swift
/// struct Note: Codable, Identifiable {
///     var id: UUID
///     @Reference<Folder>(action: .deleteSelf) var folder: Folder.ID? = nil
/// }
///
/// let note = Note(id: UUID(), folder: folder.id)
/// note.folder        // the folder's id
/// note.$folder.zone  // where it lives, once the note is saved and read back
/// ```
///
/// The property is set when the model is created or decoded and cannot be assigned
/// afterwards. It encodes a ``RecordReference`` named by the target's record name, so a
/// record encoder can tell a reference from a plain value and the action travels with it.
/// A `nil` reference is left out of a keyed container, and a missing key decodes as `nil`.
///
/// CloudKit requires a reference to point into the zone of the record that holds it, so
/// the target's zone is always the holding record's. ``zone`` is `nil` for a value built in
/// code, and the container fills it in when it saves the record. The projected value is the
/// wrapper itself, which carries the target's type, id and zone together.
///
/// The action follows `CKRecord.Reference`: with `.deleteSelf`, the record holding the
/// property deletes itself when the target is deleted. A decoded reference keeps the action
/// it was saved with, and a decoded `nil` reference has the action `.none`, because Swift
/// does not pass the attribute's arguments to `init(from:)`.
///
/// `isParent` makes the target the record's parent, saved as the record's `parent`.
/// CloudKit shares a record together with every record whose parent points at it, so
/// sharing a folder shares its notes:
///
/// ```swift
/// @Reference<Folder>(isParent: true) var folder: Folder.ID? = nil
/// ```
///
/// A parent has no action, because CloudKit requires a parent reference to have the action
/// `.none`, and a record has at most one parent. The reference encodes `isParent`, so the
/// flag survives decoding and merging.
@propertyWrapper
public struct Reference<Target: Identifiable>: Hashable, Sendable where Target.ID: Codable & Sendable {
    public let wrappedValue: Target.ID?
    public let action: RecordReference.Action
    /// Whether the target is the record's parent.
    public let isParent: Bool
    /// The zone the target lives in, the holding record's, or `nil` until the record is saved.
    public let zone: Zone?

    /// The reference itself, with the target's type, id and zone.
    public var projectedValue: Self { self }

    public init(wrappedValue: Target.ID? = nil, action: RecordReference.Action = .none) {
        self.init(wrappedValue, action: action, isParent: false, zone: nil)
    }

    /// A reference to the record's parent when `isParent` is true, with the action `.none`.
    public init(wrappedValue: Target.ID? = nil, isParent: Bool) {
        self.init(wrappedValue, action: .none, isParent: isParent, zone: nil)
    }

    private init(_ id: Target.ID?, action: RecordReference.Action, isParent: Bool, zone: Zone?) {
        wrappedValue = id
        self.action = action
        self.isParent = isParent
        self.zone = zone
    }
}

extension Reference: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard !container.decodeNil() else {
            self.init()
            return
        }
        let reference = try container.decode(RecordReference.self)
        // A schema placeholder's reference has an empty name, which no record has.
        guard !reference.recordName.isEmpty else {
            self.init()
            return
        }
        self.init(try Target.ID(reference, in: container), action: reference.action, isParent: reference.isParent, zone: reference.placedZone)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(RecordReference(to: Target.self, id: wrappedValue, zone: zone, action: action, isParent: isParent))
        } else {
            try container.encodeNil()
        }
    }
}

// Synthesized `Codable` calls these instead of the generic methods, so a `nil` reference
// behaves like an optional property: left out when encoding, and `nil` when its key is
// missing.
extension KeyedDecodingContainer {
    public func decode<Target>(_ type: Reference<Target>.Type, forKey key: Key) throws -> Reference<Target> {
        try decodeIfPresent(type, forKey: key) ?? Reference()
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<Target>(_ value: Reference<Target>, forKey key: Key) throws {
        guard value.wrappedValue != nil else { return }
        try encodeIfPresent(Optional(value), forKey: key)
    }
}

extension RecordReference {
    /// A reference to the record of type `target` whose id is `id`, named as the container
    /// names it.
    init<Target>(to target: Target.Type, id: any Encodable, zone: Zone?, action: Action = .none, isParent: Bool = false) throws {
        let name = try RecordContainer.recordName(for: id, type: RecordContainer.recordType(of: target))
        self = isParent
            ? RecordReference(parent: name, zone: zone?.name, owner: zone?.owner)
            : RecordReference(recordName: name, zone: zone?.name, owner: zone?.owner, action: action)
    }

    /// The zone the reference names, or `nil` when it names none.
    var placedZone: Zone? {
        zone.map { Zone($0, owner: owner ?? Zone.defaultOwner) }
    }
}

extension Decodable {
    /// The id a stored reference names. Throws when its name is not one made from this type.
    init(_ reference: RecordReference, in container: any SingleValueDecodingContainer) throws {
        guard let id = RecordContainer.id(Self.self, fromRecordName: reference.recordName) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "The record name \"\(reference.recordName)\" is not a \(Self.self) id.")
        }
        self = id
    }
}
