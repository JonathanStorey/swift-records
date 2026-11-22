import Foundation

/// A list of ids encoded as ``RecordReference`` values, with
/// no target type, for ``Relationship``, whose two references can point at
/// records of different types.
///
/// Only this package can create one. Clients see it only as the wrapper
/// behind `Relationship.references`.
@propertyWrapper
public struct Related: Codable, Hashable, Sendable {
    public var wrappedValue: [UUID]

    package init(_ ids: [UUID]) {
        wrappedValue = ids
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode([RecordReference].self).map { reference in
            guard let id = UUID(uuidString: reference.recordName) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Record name \"\(reference.recordName)\" is not a UUID.")
            }
            return id
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.map { RecordReference(recordName: $0.uuidString) })
    }
}
