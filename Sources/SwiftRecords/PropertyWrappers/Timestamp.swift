import Foundation

/// A read-only date that the server sets, such as when CloudKit last
/// modified the record.
///
/// ```swift
/// struct Note: Codable, Hashable {
///     var title: String
///     @Timestamp var updatedOnServer: Date? = nil
/// }
/// ```
///
/// The value comes in when a model is decoded, from a record or from JSON
/// that holds it, and is never written back: a keyed container leaves it out,
/// so encoding a model never sends the server's date to the server. It also
/// takes no part in equality or hashing, so two copies of a model that
/// differ only in when the server saved them are equal.
@propertyWrapper
public struct Timestamp: Hashable, Sendable {
    public let wrappedValue: Date?

    public init(wrappedValue: Date? = nil) {
        self.wrappedValue = wrappedValue
    }

    /// Always true, so the date never affects a model's equality.
    public static func == (lhs: Timestamp, rhs: Timestamp) -> Bool {
        true
    }

    /// Adds nothing, so the date never affects a model's hash.
    public func hash(into hasher: inout Hasher) {}
}

extension Timestamp: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wrappedValue: container.decodeNil() ? nil : try container.decode(Date.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

// Synthesized `Codable` calls these instead of the generic methods, so a
// timestamp is read when present and never written.
extension KeyedDecodingContainer {
    public func decode(_ type: Timestamp.Type, forKey key: Key) throws -> Timestamp {
        try decodeIfPresent(type, forKey: key) ?? Timestamp()
    }
}

extension KeyedEncodingContainer {
    public mutating func encode(_ value: Timestamp, forKey key: Key) throws {}
}
