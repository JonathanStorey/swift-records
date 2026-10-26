import Foundation

/// The wrapper `@Record` adds to each `@Reference(to:)` array or optional, which remembers the records
/// it held when it was fetched. Saving removes only what was taken out since then, so a child or link
/// that arrived from another device after the fetch survives a save of the older copy.
///
/// Two values are equal when they hold the same records, whenever each was fetched.
@propertyWrapper
public struct RelationshipStorage<Value> {
    public var wrappedValue: Value
    /// The IDs this held when fetched, or nil for a value that wasn't, which replaces whatever is stored.
    var loaded: Set<UUID>?

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    init(wrappedValue: Value, loaded: Set<UUID>?) {
        self.wrappedValue = wrappedValue
        self.loaded = loaded
    }
}

extension RelationshipStorage: Sendable where Value: Sendable {}

extension RelationshipStorage: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.wrappedValue == rhs.wrappedValue }
}

extension RelationshipStorage: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(wrappedValue) }
}

extension RelationshipStorage: Codable where Value: Codable {
    public init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// A relationship wrapper seen without its type, so the record coders can read and build one.
protocol AnyRelationshipStorage {
    static var collectionType: any RecordCollection.Type { get }
    var records: [any Record] { get }
    var loaded: Set<UUID>? { get }
    static func make(from records: [any Record], loaded: Set<UUID>) -> Self
}

extension RelationshipStorage: AnyRelationshipStorage where Value: RecordCollection {
    static var collectionType: any RecordCollection.Type { Value.self }
    var records: [any Record] { wrappedValue.records }

    static func make(from records: [any Record], loaded: Set<UUID>) -> Self {
        Self(wrappedValue: Value.make(from: records), loaded: loaded)
    }
}

extension KeyedDecodingContainer {
    /// Lets a record decode without its relationship's key, as an empty array or nil.
    public func decode<Value: Codable>(_ type: RelationshipStorage<Value>.Type, forKey key: Key) throws -> RelationshipStorage<Value> {
        func decoded<T: Decodable>(_ type: T.Type) throws -> T { try decode(type, forKey: key) }
        if !contains(key), let collection = Value.self as? any RecordCollection.Type {
            return RelationshipStorage(wrappedValue: collection.make(from: []) as! Value)
        }
        return try decoded(type)
    }
}
