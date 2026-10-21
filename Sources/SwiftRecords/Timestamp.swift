import Foundation

/// A `Date?` property the container sets, never your code: when the record was created, last changed,
/// or last synced.
///
/// ```swift
/// @Record
/// struct Recipe {
///     var id = UUID()
///     var title: String
///     @Timestamp(.created) var created: Date?    // stamped on the first save
///     @Timestamp(.modified) var modified: Date?  // stamped on each save that changes the record
///     @Timestamp(.synced) var synced: Date?      // nil while the server lacks this version
/// }
/// ```
///
/// `.created` and `.modified` are stored and synced like other properties, so they work in predicates
/// and every device agrees on them. They use the clock of the device that made the change. `.synced` is
/// this device's own view: when the server acknowledged the record as it is now, or `nil` while it has
/// changes the server doesn't. It isn't stored or sent, and a predicate on it runs in memory.
@propertyWrapper
public struct Timestamp: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable {
        case created
        case modified
        case synced
    }

    var date: Date?

    /// The kind is read by `@Record`, which tells the container what to stamp.
    public init(_ kind: Kind = .modified) {}

    init(date: Date?) {
        self.date = date
    }

    public var wrappedValue: Date? { date }

    public init(from decoder: Decoder) throws {
        date = try decoder.singleValueContainer().decode(Date?.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(date)
    }
}

extension KeyedDecodingContainer {
    /// Lets a record decode without its timestamp key, as a plain optional property would.
    public func decode(_ type: Timestamp.Type, forKey key: Key) throws -> Timestamp {
        try decodeIfPresent(type, forKey: key) ?? Timestamp(date: nil)
    }
}
