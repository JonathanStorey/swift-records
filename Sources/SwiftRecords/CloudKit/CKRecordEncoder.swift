import Versioning
#if canImport(CloudKit)
import CloudKit
import CoreLocation

/// Encodes an `Encodable` value onto a `CKRecord`, field by field, the reverse of
/// ``CKRecordDecoder``.
///
/// ```swift
/// try CKRecordEncoder().encode(note, to: record)
/// ```
///
/// The record keeps its system fields, so encoding onto the server's last copy uploads
/// as a change to it. An `id` is written as an ordinary field. `@Encrypted` values go to
/// `encryptedValues`. Fields the value does not write are removed, so a
/// property set to `nil` is cleared. Each value is written as the CloudKit value that
/// ``CKRecordDecoder`` reads it from:
///
/// - `String`, numbers, `Bool` (as 0 or 1), `Date` and `Data` as themselves, and `URL` as
///   its absolute string.
/// - `@Asset` as a `CKAsset`, ``Location`` as a `CLLocation`, and
///   ``RecordReference`` as a `CKRecord.Reference` in the record's zone,
///   also set as the record's `parent` when it is one.
/// - Arrays and sets as lists, with each nested value in them as `Data` holding its JSON.
/// - Anything else, such as a nested value, a dictionary, a list of lists, or a list
///   holding `nil`, as `Data` holding its JSON.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
struct CKRecordEncoder {
    func encode<T: Encodable>(_ value: T, to record: CKRecord) throws {
        let encoder = RecordEncoder(record: record)
        try value.encode(to: encoder)
        guard encoder.isKeyed else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "\(T.self) does not encode a keyed container, so it is not a record."))
        }
        // A record's keys include its encrypted keys, which only `encryptedValues` may clear.
        let encrypted = Set(record.encryptedValues.allKeys())
        for key in encrypted where !encoder.written.contains(key) { record.encryptedValues[key] = nil }
        for key in record.allKeys() where !encrypted.contains(key) && !encoder.written.contains(key) { record[key] = nil }
        if !encoder.wroteParent, record.parent != nil { record.parent = nil }
    }
}

// MARK: - Record

/// Writes the top-level value's keyed container onto the record.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private final class RecordEncoder: Encoder {
    let record: CKRecord
    var written: Set<String> = []
    var wroteParent = false
    var isKeyed = false

    init(record: CKRecord) {
        self.record = record
    }

    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        isKeyed = true
        return KeyedEncodingContainer(FieldContainer(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        ListContainer(encoder: FieldEncoder(owner: self, codingPath: []))
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        FieldEncoder(owner: self, codingPath: [])
    }

    /// Writes `value` to the field `key`, or removes the field when `value` has no value.
    func write<T: Encodable>(_ value: T, forKey key: some CodingKey) throws {
        let name = key.stringValue
        let boxed = try FieldEncoder.box(value, owner: self, codingPath: [key]) as? CKRecordValue
        written.insert(name)
        if value is any EncryptedValue {
            record.encryptedValues[name] = boxed
        } else {
            record[name] = boxed
        }
    }
}

/// The record's fields. With no encoder, it writes nothing, for a nested value that is
/// stored as JSON instead.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private struct FieldContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: RecordEncoder?
    var codingPath: [any CodingKey] { [] }

    mutating func encodeNil(forKey key: Key) throws {
        encoder?.written.remove(key.stringValue)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: String, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try encoder?.write(value, forKey: key) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try encoder?.write(value, forKey: key) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(FieldContainer<NestedKey>(encoder: nil))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        ListContainer(encoder: FieldEncoder(owner: encoder, codingPath: [key]))
    }

    mutating func superEncoder() -> any Encoder {
        encoder ?? FieldEncoder(owner: nil, codingPath: [])
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        FieldEncoder(owner: encoder, codingPath: [key])
    }
}

// MARK: - Values

/// Encodes one value of a record into its CloudKit value, noting when it has no CloudKit
/// form and must be stored as JSON.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private final class FieldEncoder: Encoder, SingleValueEncodingContainer {
    /// The record the value belongs to, for the zone and parent of its references, or `nil`
    /// for a value that is stored as JSON.
    let owner: RecordEncoder?
    let codingPath: [any CodingKey]
    /// The CloudKit value, or `nil` for `nil`.
    var value: Any?
    /// Whether the value has no CloudKit form, because it is keyed, or a list holding a
    /// list or `nil`.
    var needsJSON = false

    init(owner: RecordEncoder?, codingPath: [any CodingKey]) {
        self.owner = owner
        self.codingPath = codingPath
    }

    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        needsJSON = true
        return KeyedEncodingContainer(FieldContainer(encoder: nil))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        ListContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer { self }

    func encodeNil() throws { value = nil }
    func encode(_ value: Bool) throws { self.value = NSNumber(value: Int64(value ? 1 : 0)) }
    func encode(_ value: String) throws { self.value = value as NSString }
    func encode(_ value: Double) throws { self.value = NSNumber(value: value) }
    func encode(_ value: Float) throws { self.value = NSNumber(value: Double(value)) }
    func encode(_ value: Int) throws { try integer(value) }
    func encode(_ value: Int8) throws { try integer(value) }
    func encode(_ value: Int16) throws { try integer(value) }
    func encode(_ value: Int32) throws { try integer(value) }
    func encode(_ value: Int64) throws { try integer(value) }
    func encode(_ value: UInt) throws { try integer(value) }
    func encode(_ value: UInt8) throws { try integer(value) }
    func encode(_ value: UInt16) throws { try integer(value) }
    func encode(_ value: UInt32) throws { try integer(value) }
    func encode(_ value: UInt64) throws { try integer(value) }

    func encode<T: Encodable>(_ value: T) throws {
        self.value = try Self.box(value, owner: owner, codingPath: codingPath)
    }

    /// CloudKit stores integers as `Int64`.
    private func integer<T: FixedWidthInteger>(_ integer: T) throws {
        guard let exact = Int64(exactly: integer) else {
            throw EncodingError.invalidValue(integer, .init(codingPath: codingPath, debugDescription: "\(integer) does not fit in the Int64 CloudKit stores."))
        }
        value = NSNumber(value: exact)
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension FieldEncoder {
    /// `value` as the CloudKit value that stores it, or `nil` when it has no value.
    static func box<T: Encodable>(_ value: T, owner: RecordEncoder?, codingPath: [any CodingKey]) throws -> Any? {
        switch value {
        case let date as Date: return date as NSDate
        case let data as Data: return data as NSData
        case let url as URL: return url.absoluteString as NSString
        case let asset as any AnyAsset: return asset.projectedValue.map { CKAsset(fileURL: $0) }
        case let location as Location: return location.clLocation
        case let reference as RecordReference: return reference.ckReference(in: owner)
        default:
            let encoder = FieldEncoder(owner: owner, codingPath: codingPath)
            try value.encode(to: encoder)
            guard encoder.needsJSON else { return encoder.value }
            return Data(try JSONRepresentation(value).description.utf8) as NSData
        }
    }
}

/// A list, which CloudKit stores only when it holds no `nil` and no other list. Each
/// element that has no CloudKit form of its own is stored as JSON.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private struct ListContainer: UnkeyedEncodingContainer {
    let encoder: FieldEncoder
    private(set) var elements: [Any] = []

    init(encoder: FieldEncoder) {
        self.encoder = encoder
        encoder.value = NSArray()
    }

    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int { elements.count }

    mutating func encodeNil() throws { encoder.needsJSON = true }
    mutating func encode(_ value: Bool) throws { try append(value) }
    mutating func encode(_ value: String) throws { try append(value) }
    mutating func encode(_ value: Double) throws { try append(value) }
    mutating func encode(_ value: Float) throws { try append(value) }
    mutating func encode(_ value: Int) throws { try append(value) }
    mutating func encode(_ value: Int8) throws { try append(value) }
    mutating func encode(_ value: Int16) throws { try append(value) }
    mutating func encode(_ value: Int32) throws { try append(value) }
    mutating func encode(_ value: Int64) throws { try append(value) }
    mutating func encode(_ value: UInt) throws { try append(value) }
    mutating func encode(_ value: UInt8) throws { try append(value) }
    mutating func encode(_ value: UInt16) throws { try append(value) }
    mutating func encode(_ value: UInt32) throws { try append(value) }
    mutating func encode(_ value: UInt64) throws { try append(value) }
    mutating func encode<T: Encodable>(_ value: T) throws { try append(value) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        encoder.needsJSON = true
        return KeyedEncodingContainer(FieldContainer(encoder: nil))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        encoder.needsJSON = true
        return ListContainer(encoder: FieldEncoder(owner: nil, codingPath: codingPath))
    }

    mutating func superEncoder() -> any Encoder {
        encoder.needsJSON = true
        return FieldEncoder(owner: nil, codingPath: codingPath)
    }

    private mutating func append<T: Encodable>(_ value: T) throws {
        let path = codingPath + [JSONRepresentation.Path.Segment.index(elements.count)]
        guard let boxed = try FieldEncoder.box(value, owner: encoder.owner, codingPath: path), !(boxed is NSArray) else {
            encoder.needsJSON = true
            return
        }
        elements.append(boxed)
        encoder.value = elements as NSArray
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension RecordReference {
    /// The reference in the zone of `owner`'s record, and, when it is the parent, set as
    /// that record's parent too.
    func ckReference(in owner: RecordEncoder?) -> CKRecord.Reference {
        let zoneID = owner?.record.recordID.zoneID ?? CKRecordZone.ID.default
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let reference = CKRecord.Reference(recordID: recordID, action: action == .deleteSelf ? .deleteSelf : .none)
        if isParent, let owner {
            owner.record.parent = reference
            owner.wroteParent = true
        }
        return reference
    }
}
#endif
