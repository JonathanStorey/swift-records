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
///     var notes: [Note] = []
/// }
///
/// @Record
/// struct Note {
///     var id = UUID()
///     @Reference(to: \ToDo.notes, action: .deleteSelf) var todo: ToDo.ID?
/// }
/// ```
public protocol Record: Identifiable, Codable, Sendable where ID == UUID {
    static var schema: RecordSchema<Self> { get }
}

extension Record {
    /// `schema`, built once per type. The macro's `schema` builds its fields each time it's read, and
    /// the store reads it several times for every record it writes or loads.
    static var cachedSchema: RecordSchema<Self> {
        SchemaCache.shared.schema(for: Self.self)
    }
}

private final class SchemaCache: @unchecked Sendable {
    static let shared = SchemaCache()
    private let lock = NSLock()
    private var schemas: [ObjectIdentifier: Any] = [:]

    func schema<R: Record>(for type: R.Type) -> RecordSchema<R> {
        let key = ObjectIdentifier(type)
        if let schema = lock.withLock({ schemas[key] }) as? RecordSchema<R> {
            return schema
        }
        let schema = R.schema
        lock.withLock { schemas[key] = schema }
        return schema
    }
}

/// Generates `Record` conformance and the type's `schema`. The table is named after the struct.
@attached(extension, conformances: Record, names: named(schema))
@attached(memberAttribute)
public macro Record() = #externalMacro(module: "SwiftRecordsMacros", type: "RecordMacro")

/// Generates `Record` conformance and stores the type under a fixed name, so renaming the struct keeps
/// its data. Use letters, digits and underscores, which a CloudKit record type also allows.
@attached(extension, conformances: Record, names: named(schema))
@attached(memberAttribute)
public macro Record(_ name: String) = #externalMacro(module: "SwiftRecordsMacros", type: "RecordMacro")

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

/// Declares a child's reference to its parent: the ID of the record whose `parent` relationship holds
/// this one. The property's type is `Parent.ID?`. It is how a record says it belongs to one parent, and
/// it decides membership: saving the parent with this record in its array sets it, and setting it moves
/// the record to the end of the new parent's array. With a sync provider it crosses as a reference to the
/// parent, the way a `CKRecord.Reference` does.
///
/// ```swift
/// @Reference(to: \ToDo.notes, action: .deleteSelf) var todo: ToDo.ID?
/// ```
@attached(peer)
public macro Reference<Parent: Record, Children>(to parent: KeyPath<Parent, Children>, action: ReferenceAction) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares a child's reference to its parent with the action `.none`, so deleting the parent keeps
/// this record and clears the reference.
@attached(peer)
public macro Reference<Parent: Record, Children>(to parent: KeyPath<Parent, Children>) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares an inverse relationship: the IDs of every record whose `inverse` property contains this
/// one. The property's type is `Set<Owner.ID>`, since the owners link here in no particular order.
/// Load them with `context.fetch(Owner.self, ids:)`, and filter by them with
/// `#Predicate { $0.todoIDs.contains(todo.id) }`, which runs as SQL.
///
/// ```swift
/// @Reference(from: \ToDo.notes) var todoIDs: Set<ToDo.ID>
/// ```
@attached(peer)
public macro Reference<Owner: Record, Target>(from inverse: KeyPath<Owner, Target>) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// What a child's reference does when its parent goes, named after `CKRecord.ReferenceAction`.
public enum ReferenceAction: String, Sendable, Hashable, Codable {
    /// Keep the child and clear its reference when the parent is deleted or drops it.
    case none
    /// Delete the child when the parent is deleted or drops it.
    case deleteSelf
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
        /// For a child's reference, the parent's forward key path, such as `\ToDo.notes`.
        let parent: AnyKeyPath?
        /// For a child's reference, what happens to the child when the parent goes.
        let action: ReferenceAction
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
        /// What the container stamps into a `@Timestamped` property.
        private(set) var timestamp: TimestampKind?

        init(
            name: String, keyPath: PartialKeyPath<Root>, parent: AnyKeyPath? = nil, action: ReferenceAction = .none,
            inverse: AnyKeyPath? = nil, isAsset: Bool = false, fileExtension: String = ""
        ) {
            self.name = name
            self.keyPath = keyPath
            self.parent = parent
            self.action = action
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

        public static func field(_ name: String, _ keyPath: PartialKeyPath<Root>) -> Field {
            Field(name: name, keyPath: keyPath)
        }

        public static func reference<Parent: Record, Children>(
            _ name: String, _ keyPath: KeyPath<Root, UUID?>, to parent: KeyPath<Parent, Children>, action: ReferenceAction = .none
        ) -> Field {
            Field(name: name, keyPath: keyPath, parent: parent, action: action)
        }

        public static func timestamp(_ name: String, _ keyPath: KeyPath<Root, Date?>, _ kind: TimestampKind) -> Field {
            var field = Field(name: name, keyPath: keyPath)
            field.timestamp = kind
            return field
        }

        public static func asset(_ name: String, _ keyPath: KeyPath<Root, Data?>, fileExtension: String = "") -> Field {
            Field(name: name, keyPath: keyPath, isAsset: true, fileExtension: fileExtension)
        }

        public static func inverse<Owner: Record, Target>(
            _ name: String, _ keyPath: PartialKeyPath<Root>, of inverse: KeyPath<Owner, Target>
        ) -> Field {
            Field(name: name, keyPath: keyPath, inverse: inverse)
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
    static var table: String { cachedSchema.table }

    /// The stored name of the property at `keyPath`.
    static func fieldName(for keyPath: AnyKeyPath) -> String? {
        cachedSchema.field(for: keyPath)?.name
    }

    var sqlID: SQLiteValue {
        get throws { try ValueCoding.encode(id) }
    }
}

extension UUID {
    /// Whether this ID lists before `other`. Records are listed by ID, and comparing the strings matches
    /// SQLite's order for the stored bytes.
    func precedes(_ other: UUID) -> Bool {
        uuidString < other.uuidString
    }
}
