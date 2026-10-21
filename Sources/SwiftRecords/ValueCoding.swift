import Foundation

/// Converts a single property value to and from a SQLite value.
///
/// Values that encode as one primitive (numbers, strings, `UUID`, `Date`, `URL`, `Data`, raw-value
/// enums) get a native column value so they can be queried. Anything structured is stored as JSON text.
/// A `UUID` is stored as its 16 bytes, which keeps keys and join tables compact.
enum ValueCoding {
    static func encode(_ value: some Encodable) throws -> SQLiteValue {
        if let special = specialValue(value) { return special }
        let encoder = PrimitiveEncoder()
        do {
            try value.encode(to: encoder)
            if !encoder.isStructured, let result = encoder.result { return result }
        } catch is NeedsJSON {}
        return .text(String(decoding: try CanonicalJSON.encode(value), as: UTF8.self))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: SQLiteValue) throws -> T {
        if let special = try specialDecode(type, value) { return special }
        do {
            return try T(from: PrimitiveDecoder(storage: .value(value)))
        } catch is NeedsJSON {
            guard case .text(let json) = value else {
                throw DecodingError.typeMismatch(T.self, .init(codingPath: [], debugDescription: "Expected JSON text, found \(value)"))
            }
            return try jsonDecoder.decode(T.self, from: Data(json.utf8))
        }
    }

    /// A decoder positioned at the JSON in `value`, for a nested container in a record's own `init(from:)`.
    static func jsonDecoder(for value: SQLiteValue) throws -> Decoder {
        guard case .text(let json) = value else {
            throw DecodingError.typeMismatch([String: Any].self, .init(codingPath: [], debugDescription: "Expected JSON text, found \(value)"))
        }
        return try jsonDecoder.decode(DecoderCapture.self, from: Data(json.utf8)).decoder
    }

    private struct DecoderCapture: Decodable {
        let decoder: Decoder
        init(from decoder: Decoder) { self.decoder = decoder }
    }

    /// Decodes an array of values, such as the IDs of an inverse relationship.
    static func decode<T: Decodable>(_ type: T.Type, fromArray values: [SQLiteValue]) throws -> T {
        try T(from: PrimitiveDecoder(storage: .array(values)))
    }

    private static func specialValue(_ value: Any) -> SQLiteValue? {
        switch value {
        case let uuid as UUID: .blob(withUnsafeBytes(of: uuid.uuid) { Data($0) })
        case let date as Date: .real(date.timeIntervalSince1970)
        case let url as URL: .text(url.absoluteString)
        case let data as Data: .blob(data)
        default: nil
        }
    }

    private static func specialDecode<T>(_ type: T.Type, _ value: SQLiteValue) throws -> T? {
        func mismatch() -> DecodingError {
            .typeMismatch(T.self, .init(codingPath: [], debugDescription: "Cannot decode \(T.self) from \(value)"))
        }
        if T.self == UUID.self {
            switch value {
            case .blob(let data) where data.count == 16:
                var bytes = UUID().uuid
                withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: data) }
                return UUID(uuid: bytes) as? T
            case .text(let text):
                guard let uuid = UUID(uuidString: text) else { throw mismatch() }
                return uuid as? T
            default:
                throw mismatch()
            }
        }
        if T.self == Date.self {
            switch value {
            case .real(let seconds): return Date(timeIntervalSince1970: seconds) as? T
            case .integer(let seconds): return Date(timeIntervalSince1970: Double(seconds)) as? T
            default: throw mismatch()
            }
        }
        if T.self == URL.self {
            guard case .text(let text) = value, let url = URL(string: text) else { throw mismatch() }
            return url as? T
        }
        if T.self == Data.self {
            guard case .blob(let data) = value else { throw mismatch() }
            return data as? T
        }
        return nil
    }

    static let jsonDecoder = JSONDecoder()
}

/// Thrown when a value needs a keyed or unkeyed container, meaning it must be stored as JSON.
struct NeedsJSON: Error {}

// MARK: - Encoding

private final class PrimitiveEncoder: Encoder, SingleValueEncodingContainer {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var result: SQLiteValue?
    var isStructured = false

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        isStructured = true
        return KeyedEncodingContainer(RejectingKeyedContainer<Key>())
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        isStructured = true
        return RejectingUnkeyedContainer()
    }

    func singleValueContainer() -> SingleValueEncodingContainer { self }

    func encodeNil() throws { result = .null }
    func encode(_ value: Bool) throws { result = .integer(value ? 1 : 0) }
    func encode(_ value: String) throws { result = .text(value) }
    func encode(_ value: Double) throws {
        // SQLite would store NaN as NULL, which reads back as nil or the default, so refuse it like `JSONEncoder`.
        guard !value.isNaN else {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "NaN can't be stored"))
        }
        result = .real(value)
    }
    func encode(_ value: Float) throws { try encode(Double(value)) }
    func encode(_ value: Int) throws { result = .integer(Int64(value)) }
    func encode(_ value: Int8) throws { result = .integer(Int64(value)) }
    func encode(_ value: Int16) throws { result = .integer(Int64(value)) }
    func encode(_ value: Int32) throws { result = .integer(Int64(value)) }
    func encode(_ value: Int64) throws { result = .integer(value) }
    func encode(_ value: UInt) throws { try encode(UInt64(value)) }
    func encode(_ value: UInt8) throws { result = .integer(Int64(value)) }
    func encode(_ value: UInt16) throws { result = .integer(Int64(value)) }
    func encode(_ value: UInt32) throws { result = .integer(Int64(value)) }
    /// Values above `Int64.max` are stored as text, which sorts above every integer, so SQL comparisons with
    /// smaller values stay right.
    func encode(_ value: UInt64) throws { result = Int64(exactly: value).map { .integer($0) } ?? .text(String(value)) }

    func encode<T: Encodable>(_ value: T) throws {
        result = try ValueCoding.encode(value)
    }
}

private struct RejectingKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    var codingPath: [CodingKey] = []
    func encodeNil(forKey key: Key) throws { throw NeedsJSON() }
    func encode<T: Encodable>(_ value: T, forKey key: Key) throws { throw NeedsJSON() }
    func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(RejectingKeyedContainer<NestedKey>())
    }
    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { RejectingUnkeyedContainer() }
    func superEncoder() -> Encoder { PrimitiveEncoder() }
    func superEncoder(forKey key: Key) -> Encoder { PrimitiveEncoder() }
}

private struct RejectingUnkeyedContainer: UnkeyedEncodingContainer {
    var codingPath: [CodingKey] = []
    var count = 0
    func encodeNil() throws { throw NeedsJSON() }
    func encode<T: Encodable>(_ value: T) throws { throw NeedsJSON() }
    func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(RejectingKeyedContainer<NestedKey>())
    }
    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { RejectingUnkeyedContainer() }
    func superEncoder() -> Encoder { PrimitiveEncoder() }
}

// MARK: - Decoding

private struct PrimitiveDecoder: Decoder {
    enum Storage {
        case value(SQLiteValue)
        case array([SQLiteValue])
    }

    let storage: Storage
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw NeedsJSON()
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let values) = storage else { throw NeedsJSON() }
        return PrimitiveUnkeyedContainer(values: values)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        guard case .value(let value) = storage else { throw NeedsJSON() }
        return PrimitiveSingleValueContainer(value: value)
    }
}

private struct PrimitiveSingleValueContainer: SingleValueDecodingContainer {
    let value: SQLiteValue
    var codingPath: [CodingKey] = []

    func decodeNil() -> Bool { value == .null }

    func decode(_ type: Bool.Type) throws -> Bool { try integer() != 0 }
    func decode(_ type: String.Type) throws -> String {
        guard case .text(let text) = value else { throw mismatch(type) }
        return text
    }
    func decode(_ type: Double.Type) throws -> Double {
        switch value {
        case .real(let double): return double
        case .integer(let int): return Double(int)
        default: throw mismatch(type)
        }
    }
    func decode(_ type: Float.Type) throws -> Float { Float(try decode(Double.self)) }
    func decode(_ type: Int.Type) throws -> Int { try exactly(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try exactly(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try exactly(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try exactly(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer() }
    func decode(_ type: UInt.Type) throws -> UInt {
        guard let value = UInt(exactly: try decode(UInt64.self)) else { throw mismatch(type) }
        return value
    }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try exactly(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try exactly(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try exactly(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        switch value {
        case .text(let text):
            guard let value = UInt64(text) else { throw mismatch(type) }
            return value
        case .integer(let int) where int < 0:
            // Earlier versions stored values above `Int64.max` as their bit pattern.
            return UInt64(bitPattern: int)
        default:
            guard let value = UInt64(exactly: try integer()) else { throw mismatch(type) }
            return value
        }
    }

    /// An integer that fits `type`, or a decoding error instead of a trap when it doesn't.
    private func exactly<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let value = T(exactly: try integer()) else { throw mismatch(type) }
        return value
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try ValueCoding.decode(type, from: value)
    }

    private func integer() throws -> Int64 {
        switch value {
        case .integer(let int): return int
        case .real(let double):
            guard let int = Int64(exactly: double.rounded(.towardZero)) else { throw mismatch(Int64.self) }
            return int
        default: throw mismatch(Int64.self)
        }
    }

    private func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Found \(value)"))
    }
}

private struct PrimitiveUnkeyedContainer: UnkeyedDecodingContainer {
    let values: [SQLiteValue]
    var codingPath: [CodingKey] = []
    var currentIndex = 0
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }

    mutating func decodeNil() throws -> Bool {
        guard values[currentIndex] == .null else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(type, .init(codingPath: codingPath, debugDescription: "Unkeyed container is at end"))
        }
        defer { currentIndex += 1 }
        return try ValueCoding.decode(type, from: values[currentIndex])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        throw NeedsJSON()
    }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { throw NeedsJSON() }
    mutating func superDecoder() throws -> Decoder { throw NeedsJSON() }
}
