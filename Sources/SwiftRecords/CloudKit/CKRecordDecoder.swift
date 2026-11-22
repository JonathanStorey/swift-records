import Versioning
#if canImport(CloudKit)
import CloudKit
import CoreLocation

/// Decodes a `Decodable` type from a `CKRecord`, field by field, as `JSONDecoder` decodes it
/// from an object.
///
/// ```swift
/// let note = try CKRecordDecoder().decode(Note.self, from: record)
/// ```
///
/// Each key reads the field of that name, or, when the record has none, the encrypted
/// field, so `@Encrypted` needs nothing more. An `id` is an ordinary field, because the
/// record's name may be a hash of it. Each type is read from the CloudKit value that stores it:
///
/// - `String`, numbers, `Bool` (as 0 or 1), `Date` and `Data` from the value itself.
/// - `URL` from a string, or from a `CKAsset`'s file, which is how `@Asset` reads.
/// - ``Location`` from a `CLLocation`.
/// - ``RecordReference`` from a `CKRecord.Reference`, with its zone and
///   owner, and marked as the parent when it points at the record's `parent`.
/// - Arrays and sets from lists.
/// - Anything else, such as a nested value, a dictionary, or a list of lists, from `Data`
///   holding its JSON.
///
/// A missing field decodes as `nil`, so `@Timestamp` and optionals read as `nil`.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
struct CKRecordDecoder {
    func decode<T: Decodable>(_ type: T.Type, from record: CKRecord) throws -> T {
        try FieldDecoder(value: record, record: record, codingPath: []).decode(type)
    }
}

// MARK: - Values

/// Decodes one value of a record, or, at the top, the record itself.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private struct FieldDecoder: Decoder, SingleValueDecodingContainer {
    let value: Any
    let record: CKRecord
    let codingPath: [any CodingKey]

    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard (value as? CKRecord) === record else { throw mismatch([String: Any].self) }
        return KeyedDecodingContainer(FieldContainer(record: record, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        ListContainer(elements: try cast([Any].self), record: record, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { self }

    func decodeNil() -> Bool { value is NSNull }

    func decode(_ type: Bool.Type) throws -> Bool {
        switch try integer(Int64.self) {
        case 0: false
        case 1: true
        default: throw mismatch(type)
        }
    }

    func decode(_ type: String.Type) throws -> String { try cast(type) }
    func decode(_ type: Double.Type) throws -> Double { try cast(type) }
    func decode(_ type: Float.Type) throws -> Float { Float(try cast(Double.self)) }
    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoded: Any
        switch type {
        case is Date.Type: decoded = try cast(Date.self)
        case is Data.Type: decoded = try cast(Data.self)
        case is URL.Type: decoded = try url()
        case is Location.Type: decoded = Location(try cast(CLLocation.self))
        case is RecordReference.Type: decoded = try reference()
        default:
            guard let json = value as? Data else { return try T(from: self) }
            return try JSONDecoder().decode(JSONRepresentation.self, from: json).decode(type)
        }
        return decoded as! T
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension FieldDecoder {
    func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected \(type), but the record holds \(Swift.type(of: value))."))
    }

    func cast<T>(_ type: T.Type) throws -> T {
        guard let cast = value as? T else { throw mismatch(type) }
        return cast
    }

    /// The integer, when the stored number is a whole number within `T`'s bounds.
    func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let integer = T(exactly: try cast(Int64.self)) else { throw mismatch(type) }
        return integer
    }

    func url() throws -> URL {
        if let asset = value as? CKAsset, let url = asset.fileURL { return url }
        guard let url = URL(string: try cast(String.self)) else { throw mismatch(URL.self) }
        return url
    }

    func reference() throws -> RecordReference {
        let reference = try cast(CKRecord.Reference.self)
        let name = reference.recordID.recordName
        let zone = reference.recordID.zoneID
        if record.parent?.recordID.recordName == name { return .init(parent: name, zone: zone.zoneName, owner: zone.ownerName) }
        return .init(recordName: name, zone: zone.zoneName, owner: zone.ownerName, action: reference.action == .deleteSelf ? .deleteSelf : .none)
    }
}

// MARK: - Containers

/// The record's fields, plain and encrypted.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private struct FieldContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let record: CKRecord
    let codingPath: [any CodingKey]

    var allKeys: [Key] {
        var keys = record.allKeys()
        keys += record.encryptedValues.allKeys().filter { !keys.contains($0) }
        return keys.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool { value(for: key) != nil }

    func decodeNil(forKey key: Key) throws -> Bool { value(for: key).map { $0 is NSNull } ?? true }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decoder(for: key).decode(type) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decoder(for: key).decode(type) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decoder(for: key).decode(type) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decoder(for: key).decode(type) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decoder(for: key).decode(type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decoder(for: key).decode(type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decoder(for: key).decode(type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decoder(for: key).decode(type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decoder(for: key).decode(type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decoder(for: key).decode(type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decoder(for: key).decode(type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decoder(for: key).decode(type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decoder(for: key).decode(type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decoder(for: key).decode(type) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try decoder(for: key).decode(type) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try decoder(for: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try decoder(for: key).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        FieldDecoder(value: record, record: record, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        try decoder(for: key)
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private extension FieldContainer {
    func value(for key: Key) -> Any? {
        let name = key.stringValue
        let value: CKRecordValue? = record[name] ?? record.encryptedValues[name]
        return value
    }

    func decoder(for key: Key) throws -> FieldDecoder {
        guard let value = value(for: key) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "The record has no field \"\(key.stringValue)\"."))
        }
        return FieldDecoder(value: value, record: record, codingPath: codingPath + [key])
    }
}

/// A list field. CloudKit lists never hold `nil`.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private struct ListContainer: UnkeyedDecodingContainer {
    let elements: [Any]
    let record: CKRecord
    let codingPath: [any CodingKey]
    private(set) var currentIndex = 0

    init(elements: [Any], record: CKRecord, codingPath: [any CodingKey]) {
        self.elements = elements
        self.record = record
        self.codingPath = codingPath
    }

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try next().decode(type) }
    mutating func decode(_ type: String.Type) throws -> String { try next().decode(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try next().decode(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try next().decode(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try next().decode(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try next().decode(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try next().decode(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try next().decode(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try next().decode(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try next().decode(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next().decode(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next().decode(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next().decode(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next().decode(type) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next().decode(type) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try next().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try next().unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        try next()
    }

    private mutating func next() throws -> FieldDecoder {
        let path = codingPath + [JSONRepresentation.Path.Segment.index(currentIndex)]
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(Any.self, .init(codingPath: path, debugDescription: "The list has no more elements."))
        }
        defer { currentIndex += 1 }
        return FieldDecoder(value: elements[currentIndex], record: record, codingPath: path)
    }
}
#endif
