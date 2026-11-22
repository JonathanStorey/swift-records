/// A value kept only in memory, such as a cache or state for the interface.
///
/// ```swift
/// struct Note: Codable, Hashable {
///     var body: String
///     @Transient var thumbnail: Image? = nil
/// }
/// ```
///
/// It is never encoded, so it never reaches JSON or a record, and it is
/// `nil` whenever a model is decoded. Its value need not be `Codable`,
/// `Hashable` or `Sendable`, and it takes no part in equality or hashing,
/// so two copies that differ only in what they cached are equal.
@propertyWrapper
public struct Transient<Value> {
    public var wrappedValue: Value?

    public init(wrappedValue: Value? = nil) {
        self.wrappedValue = wrappedValue
    }
}

extension Transient: Hashable {
    /// Always true, so the value never affects a model's equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        true
    }

    /// Adds nothing, so the value never affects a model's hash.
    public func hash(into hasher: inout Hasher) {}
}

extension Transient: Sendable where Value: Sendable {}

extension Transient: Codable {
    /// Always `nil`, whatever the decoder holds.
    public init(from decoder: any Decoder) throws {
        self.init()
    }

    /// Writes `null`. A keyed container leaves the property out instead.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

// Synthesized `Codable` calls these instead of the generic methods, so a
// transient value is never read or written.
extension KeyedDecodingContainer {
    public func decode<Value>(_ type: Transient<Value>.Type, forKey key: Key) throws -> Transient<Value> {
        Transient()
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<Value>(_ value: Transient<Value>, forKey key: Key) throws {}
}
