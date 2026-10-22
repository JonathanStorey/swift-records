import Foundation

/// A struct stored in its own SQLite table. Adopt it with the `@Record` macro rather than directly.
///
/// A record's `id` is a `UUID`, so records created on different devices never collide, which a sync
/// layer depends on.
///
/// ```swift
/// @Record
/// struct ToDo {
///     var id = UUID()
///     var title: String
///     @Reference(deleteRule: .none) var notes: [Note] = []
/// }
/// ```
public protocol Record: Identifiable, Codable, Sendable where ID == UUID {
    static var schema: RecordSchema<Self> { get }
}

/// Generates `Record` conformance and the type's `schema`. The table is named after the struct.
@attached(extension, conformances: Record, names: named(schema))
@attached(memberAttribute)
public macro Record() = #externalMacro(module: "SwiftRecordsMacros", type: "RecordMacro")

/// Generates `Record` conformance and stores the type under a fixed name, so renaming the struct keeps
/// its data. Use letters, digits and underscores, which a CloudKit record type also allows.
@attached(extension, conformances: Record, names: named(schema))
@attached(memberAttribute)
public macro Record(name: String) = #externalMacro(module: "SwiftRecordsMacros", type: "RecordMacro")

/// Reads a property's earlier names, so renaming it in Swift keeps its stored values. The column is
/// renamed the first time the container uses the type.
///
/// ```swift
/// @Renamed(from: "minutes") var duration = 0
/// ```
@attached(peer)
public macro Renamed(from names: String...) = #externalMacro(module: "SwiftRecordsMacros", type: "MarkerMacro")

/// Adds a database index on a property, so predicates that compare it stay fast on large tables. It
/// changes nothing about how the record encodes.
@attached(peer)
public macro Indexed() = #externalMacro(module: "SwiftRecordsMacros", type: "MarkerMacro")

/// Marks a relationship with the default rule, `.cascade`. Writing it is optional.
@attached(peer)
public macro Reference() = #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Sets the delete rule for a relationship. Without it, related records are cascaded, the way a nested
/// struct disappears with its parent. Pass `.none` to unlink related records and keep them.
@attached(peer)
public macro Reference(deleteRule: DeleteRule?) = #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares an inverse relationship: the IDs of every record whose `inverse` property contains this
/// one. The property's type is `Set<Owner.ID>`, since the owners link here in no particular order.
/// Load them with `context.fetch(Owner.self, ids:)`, and filter by them with
/// `#Predicate { $0.todos.contains(todo.id) }`, which runs as SQL.
///
/// ```swift
/// @Reference(from: \ToDo.notes) var todos: Set<ToDo.ID> = []
/// ```
@attached(peer)
public macro Reference<Owner: Record, Target>(from inverse: KeyPath<Owner, Target>) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// What happens to related records when their owner is deleted or drops them. A relationship whose
/// rule is `nil` (written `.none`) unlinks them and keeps them.
public enum DeleteRule: String, Sendable {
    /// Delete related records that no other record still references. The default.
    case cascade
}

/// The property list `@Record` generates for a type. Only the macro's generated code builds one.
public struct RecordSchema<Root: Record>: @unchecked Sendable {
    let table: String
    let fields: [Field]

    public init(table: String, fields: [Field]) {
        self.table = table
        self.fields = fields
    }

    public struct Field: @unchecked Sendable {
        let name: String
        let keyPath: PartialKeyPath<Root>
        /// The delete rule for a relationship: `.cascade` unless `@Reference(deleteRule:)` says otherwise,
        /// and `nil` to keep related records.
        let deleteRule: DeleteRule?
        /// For an inverse field, the owner's forward key path, such as `\ToDo.notes`.
        let inverse: AnyKeyPath?
        /// True for an `@Asset` property, whose file lives beside the database.
        let isAsset: Bool
        /// The extension for an asset's new files.
        let fileExtension: String
        /// The property's declared default, used when a stored row has no value for it, such as a row
        /// saved before the property existed.
        private(set) var defaultValue: (@Sendable () -> Any)?
        /// Names the property was stored under before, from `@Renamed(from:)`.
        private(set) var previousNames: [String] = []
        /// True for an `@Indexed` property.
        private(set) var isIndexed = false
        /// What the container stamps into a `@Timestamp` property.
        private(set) var timestamp: TimestampKind?

        init(name: String, keyPath: PartialKeyPath<Root>, deleteRule: DeleteRule?, inverse: AnyKeyPath?, isAsset: Bool, fileExtension: String) {
            self.name = name
            self.keyPath = keyPath
            self.deleteRule = deleteRule
            self.inverse = inverse
            self.isAsset = isAsset
            self.fileExtension = fileExtension
        }

        /// The value to decode when a row has none.
        public func defaulting<Value>(_ value: @autoclosure @escaping @Sendable () -> Value) -> Field {
            var field = self
            field.defaultValue = { value() }
            return field
        }

        public func renamed(from names: String...) -> Field {
            var field = self
            field.previousNames = names
            return field
        }

        public func indexed() -> Field {
            var field = self
            field.isIndexed = true
            return field
        }

        public static func field(_ name: String, _ keyPath: PartialKeyPath<Root>, deleteRule: DeleteRule? = .cascade) -> Field {
            Field(name: name, keyPath: keyPath, deleteRule: deleteRule, inverse: nil, isAsset: false, fileExtension: "")
        }

        public static func timestamp(_ name: String, _ keyPath: KeyPath<Root, Date?>, _ kind: TimestampKind) -> Field {
            var field = Field(name: name, keyPath: keyPath, deleteRule: .cascade, inverse: nil, isAsset: false, fileExtension: "")
            field.timestamp = kind
            return field
        }

        public static func asset(_ name: String, _ keyPath: KeyPath<Root, Data?>, fileExtension: String = "") -> Field {
            Field(name: name, keyPath: keyPath, deleteRule: .cascade, inverse: nil, isAsset: true, fileExtension: fileExtension)
        }

        public static func inverse<Owner: Record, Target>(
            _ name: String, _ keyPath: PartialKeyPath<Root>, of inverse: KeyPath<Owner, Target>
        ) -> Field {
            Field(name: name, keyPath: keyPath, deleteRule: .cascade, inverse: inverse, isAsset: false, fileExtension: "")
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

    /// The stored name of the property at `keyPath`.
    static func fieldName(for keyPath: AnyKeyPath) -> String? {
        schema.field(for: keyPath)?.name
    }

    var sqlID: SQLiteValue {
        get throws { try ValueCoding.encode(id) }
    }
}
