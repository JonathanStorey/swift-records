import Foundation

/// The wrapper `@Record` adds to each `@Reference(from:)` property, which makes it read-only. The
/// container fills it from the owners' links, and you change it by linking from the owner's side.
@propertyWrapper
public struct InverseStorage: Hashable, Sendable, Codable {
    var ids: Set<UUID>

    public init() {
        ids = []
    }

    init(ids: Set<UUID>) {
        self.ids = ids
    }

    public var wrappedValue: Set<UUID> { ids }

    public init(from decoder: Decoder) throws {
        ids = try decoder.singleValueContainer().decode(Set<UUID>.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ids)
    }
}

extension KeyedDecodingContainer {
    /// Lets a record decode without its inverse key, as a plain optional property would.
    public func decode(_ type: InverseStorage.Type, forKey key: Key) throws -> InverseStorage {
        try decodeIfPresent(type, forKey: key) ?? InverseStorage()
    }
}
