import Foundation

/// A struct stored in its own SQLite table. Adopt it with the `@Record` macro rather than directly.
///
/// ```swift
/// @Record
/// struct ToDo {
///     var id = UUID()
///     var title: String
///     @Reference(deleteRule: .none) var notes: [Note] = []
/// }
/// ```
public protocol Record: Identifiable, Codable, Sendable where ID: Codable & Sendable {
    static var schema: RecordSchema<Self> { get }
}

/// Generates `Record` conformance and the type's `schema`.
@attached(extension, conformances: Record, names: named(schema))
public macro Record() = #externalMacro(module: "SwiftRecordsMacros", type: "RecordMacro")

/// Sets the delete rule for a relationship. Without it, related records are cascaded, the way a nested
/// struct disappears with its parent.
@attached(peer)
public macro Reference(deleteRule: DeleteRule) = #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares an inverse relationship: the ordered IDs of every record whose `inverse` property
/// contains this one. The property's type is `[Owner.ID]`.
///
/// ```swift
/// @Reference(from: \ToDo.notes) var todos: [ToDo.ID] = []
/// ```
@attached(peer)
public macro Reference<Owner: Record, Target>(from inverse: KeyPath<Owner, Target>) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// What happens to related records when their owner is deleted or drops them.
public enum DeleteRule: String, Sendable {
    /// Delete related records that no other record still references. The default.
    case cascade
    /// Unlink related records and keep them. Databases written with the earlier name `nullify` read as this.
    case none
}

/// The property list `@Record` generates for a type.
public struct RecordSchema<Root: Record>: @unchecked Sendable {
    public let table: String
    public let fields: [Field]

    public init(table: String, fields: [Field]) {
        self.table = table
        self.fields = fields
    }

    public struct Field: @unchecked Sendable {
        public let name: String
        public let keyPath: PartialKeyPath<Root>
        /// The delete rule for a relationship. `.cascade` unless `@Reference(deleteRule:)` says otherwise.
        public let deleteRule: DeleteRule
        /// For an inverse field, the owner's forward key path, such as `\ToDo.notes`.
        public let inverse: AnyKeyPath?
        /// True for an `Asset?` property, whose file lives beside the database.
        public let isAsset: Bool

        public static func field(_ name: String, _ keyPath: PartialKeyPath<Root>, deleteRule: DeleteRule = .cascade) -> Field {
            Field(name: name, keyPath: keyPath, deleteRule: deleteRule, inverse: nil, isAsset: false)
        }

        public static func asset(_ name: String, _ keyPath: KeyPath<Root, Asset?>) -> Field {
            Field(name: name, keyPath: keyPath, deleteRule: .cascade, inverse: nil, isAsset: true)
        }

        public static func inverse<Owner: Record, Target>(
            _ name: String, _ keyPath: PartialKeyPath<Root>, of inverse: KeyPath<Owner, Target>
        ) -> Field {
            Field(name: name, keyPath: keyPath, deleteRule: .cascade, inverse: inverse, isAsset: false)
        }
    }

    func field(named name: String) -> Field? {
        fields.first { $0.name == name }
    }

    func field(for keyPath: AnyKeyPath) -> Field? {
        fields.first { $0.keyPath == keyPath }
    }
}

extension Record {
    static var table: String { schema.table }

    var sqlID: SQLiteValue {
        get throws { try ValueCoding.encode(id) }
    }
}
