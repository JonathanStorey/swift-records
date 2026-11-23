import Foundation

/// A list of record names encoded as ``RecordReference`` values, with
/// no target type, for ``Relationship``, whose two references can point at
/// records of different types.
///
/// Only this package can create one. Clients see it only as the wrapper
/// behind `Relationship.references`.
@propertyWrapper
public struct Related: Codable, Hashable, Sendable {
    public var wrappedValue: [String]

    package init(_ ids: [String]) {
        wrappedValue = ids
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode([RecordReference].self).map(\.recordName)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.map { RecordReference(recordName: $0) })
    }
}
