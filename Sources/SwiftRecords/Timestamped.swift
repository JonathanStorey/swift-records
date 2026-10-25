import Foundation

/// A `Date?` property the container sets, never your code: when the record was created, last changed,
/// or last synced.
///
/// ```swift
/// @Record
/// struct Recipe {
///     var id = UUID()
///     var title: String
///     @Timestamped(.created) var created: Date?    // stamped on the first save
///     @Timestamped(.modified) var modified: Date?  // stamped on each save that changes the record
///     @Timestamped(.synced) var synced: Date?      // nil while the server lacks this version
/// }
/// ```
///
/// `.created` and `.modified` are stored and synced like other properties, so they work in predicates
/// and every device agrees on them. They use the clock of the device that made the change. `.synced` is
/// this device's own view: when the server acknowledged the record as it is now, or `nil` while it has
/// changes the server doesn't. It isn't stored or sent, and a predicate on it runs in memory.
///
/// `@Timestamped` is a marker that `@Record` turns into a `TimestampStorage` wrapper. Outside a `@Record`
/// struct it does nothing, and the compiler warns.
@attached(peer)
public macro Timestamped(_ kind: TimestampKind = .modified) = #externalMacro(module: "SwiftRecordsMacros", type: "MarkerMacro")

/// What the container stamps into a `@Timestamped` property.
public enum TimestampKind: String, Sendable {
    case created
    case modified
    case synced
}

/// The wrapper `@Record` adds to each `@Timestamped` property. Write `@Timestamped` rather than this.
@propertyWrapper
public struct TimestampStorage: Hashable, Sendable, Codable {
    var date: Date?

    public init() {}

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
    public func decode(_ type: TimestampStorage.Type, forKey key: Key) throws -> TimestampStorage {
        try decodeIfPresent(type, forKey: key) ?? TimestampStorage(date: nil)
    }
}
