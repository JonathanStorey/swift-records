import Foundation

/// A read-only reference to another record, stored as the target's ``RecordID``.
///
/// ```swift
/// struct Note: Codable, Identifiable {
///     var id: UUID
///     @Reference(action: .deleteSelf) var folder: RecordID<Folder>? = nil
/// }
///
/// let note = Note(id: UUID(), folder: try RecordID(folder, zone: "Notes"))
/// note.folder?.name                // the folder's record name
/// ```
///
/// The property is set when the model is created or decoded and cannot be
/// assigned afterwards. The target can be any type, identified however it is
/// saved, because the reference holds where the record lives, not the
/// target's own id. The wrapper encodes a ``RecordReference``,
/// so a record encoder can tell a reference from a plain value and the action
/// travels with it. A `nil` reference is left out of a keyed container, and a
/// missing key decodes as `nil`.
///
/// The action follows `CKRecord.Reference`: with `.deleteSelf`, the record
/// holding the property deletes itself when the target is deleted. A
/// decoded reference keeps the action it was saved with, and a decoded `nil`
/// reference has the action `.none`, because Swift does not pass the
/// attribute's arguments to `init(from:)`.
///
/// `isParent` makes the target the record's parent, saved as the record's
/// `parent`. CloudKit shares a record together with every record whose
/// parent points at it, so sharing a folder shares its notes:
///
/// ```swift
/// @Reference(isParent: true) var folder: RecordID<Folder>? = nil
/// ```
///
/// A parent has no action, because CloudKit requires a parent reference to
/// have the action `.none`, and a record has at most one parent. The
/// reference encodes `isParent`, so the flag survives decoding and merging.
@propertyWrapper
public struct Reference<Target>: Hashable, Sendable {
    public let wrappedValue: RecordID<Target>?
    public let action: RecordReference.Action
    /// Whether the target is the record's parent.
    public let isParent: Bool

    public init(wrappedValue: RecordID<Target>? = nil, action: RecordReference.Action = .none) {
        self.wrappedValue = wrappedValue
        self.action = action
        isParent = false
    }

    /// A reference to the record's parent when `isParent` is true, with the action `.none`.
    public init(wrappedValue: RecordID<Target>? = nil, isParent: Bool) {
        self.wrappedValue = wrappedValue
        action = .none
        self.isParent = isParent
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
        let id = try RecordID<Target>(reference, in: container)
        self = reference.isParent ? Reference(wrappedValue: id, isParent: true) : Reference(wrappedValue: id, action: reference.action)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue.reference(action: action, isParent: isParent))
        } else {
            try container.encodeNil()
        }
    }
}

// Synthesized `Codable` calls these instead of the generic methods, so a
// `nil` reference behaves like an optional property: left out when encoding,
// and `nil` when its key is missing.
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

extension RecordID {
    /// The id a stored reference points at. Throws when its record name is not a UUID or
    /// its zone is unknown.
    init(_ reference: RecordReference, in container: any SingleValueDecodingContainer) throws {
        guard let name = UUID(uuidString: reference.recordName) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Record name \"\(reference.recordName)\" is not a UUID.")
        }
        guard let zone = reference.zone else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "The reference to \"\(reference.recordName)\" has no zone.")
        }
        self.init(name: name, zone: Zone(zone, owner: reference.owner ?? Zone.defaultOwner))
    }

    /// This id as a stored reference.
    func reference(action: RecordReference.Action = .none, isParent: Bool = false) -> RecordReference {
        isParent
            ? RecordReference(parent: name.uuidString, zone: zone.name, owner: zone.owner)
            : RecordReference(recordName: name.uuidString, zone: zone.name, owner: zone.owner, action: action)
    }
}
