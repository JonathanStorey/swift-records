import Versioning
/// A value CloudKit stores encrypted end to end, in a record's
/// `encryptedValues`.
///
/// ```swift
/// struct Note: Codable {
///     @Encrypted var body: String = ""
///     @Encrypted var pin: Int? = nil
/// }
/// ```
///
/// The wrapper only marks the property. It encodes its value through a
/// single-value container, so JSON is unchanged and an encoder's `Date` and
/// `Data` strategies still apply. CloudKit can encrypt strings, numbers, dates,
/// data, locations and lists of them, but not references or assets, and an
/// encrypted field cannot be queried, sorted or indexed.
///
/// An optional `nil` value is left out of a keyed container, and a missing
/// key decodes as `nil`.
@propertyWrapper
public struct Encrypted<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}

/// An `@Encrypted` value, which a record stores in `encryptedValues`, and which the public
/// database cannot store.
protocol EncryptedValue {}

extension Encrypted: EncryptedValue {}

extension Encrypted: Equatable where Value: Equatable {}
extension Encrypted: Hashable where Value: Hashable {}
extension Encrypted: Sendable where Value: Sendable {}

extension Encrypted: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension Encrypted: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(Value.self)
    }
}

extension Encrypted: RawRepresentable {
    /// The value, the same as ``wrappedValue``, so a plain `Encrypted`
    /// property works where a wrapper cannot, as in a SwiftData model.
    public var rawValue: Value { wrappedValue }

    public init(rawValue: Value) {
        wrappedValue = rawValue
    }
}

extension Encrypted: Mergeable where Value: Mergeable {
    /// The values merged by their own merge, so encrypting a property never
    /// changes how it merges.
    public func merging(with theirs: Encrypted, from base: Encrypted) throws(MergeConflict) -> Encrypted {
        Encrypted(wrappedValue: try wrappedValue.merging(with: theirs.wrappedValue, from: base.wrappedValue))
    }

    public func merging(with theirs: Encrypted) throws(MergeConflict) -> Encrypted {
        Encrypted(wrappedValue: try wrappedValue.merging(with: theirs.wrappedValue))
    }
}

extension KeyedDecodingContainer {
    public func decode<Wrapped: Decodable>(_ type: Encrypted<Wrapped?>.Type, forKey key: Key) throws -> Encrypted<Wrapped?> {
        try decodeIfPresent(type, forKey: key) ?? Encrypted(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    /// Encodes a present value still wrapped, so a record encoder can see that it is
    /// encrypted. The JSON is the same, since the wrapper encodes its value directly.
    public mutating func encode<Wrapped: Encodable>(_ value: Encrypted<Wrapped?>, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue.map { Encrypted<Wrapped>(wrappedValue: $0) }, forKey: key)
    }
}
