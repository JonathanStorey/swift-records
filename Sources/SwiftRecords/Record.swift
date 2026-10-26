import Foundation

/// A struct stored in its own SQLite table. Adopt it with the `@Record` macro rather than directly.
///
/// A record's `id` is a `UUID`, so records created on different devices never collide, which a sync
/// layer depends on.
///
/// ```swift
/// @Record
/// struct ToDo {
///     var id = UUID.ordered()
///     var title: String
///     @Reference(to: \Note.todo) var notes: [Note] = []
/// }
///
/// @Record
/// struct Note {
///     var id = UUID.ordered()
///     @Reference(from: ToDo.self, action: .deleteSelf) var todo: ToDo.ID?
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
@attached(member, names: named(ID))
@attached(memberAttribute)
public macro Record() = #externalMacro(module: "SwiftRecordsMacros", type: "RecordMacro")

/// Generates `Record` conformance and stores the type under a fixed name, so renaming the struct keeps
/// its data. Use letters, digits and underscores, which a CloudKit record type also allows.
@attached(extension, conformances: Record, names: named(schema))
@attached(member, names: named(ID))
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

/// Declares a stored pointer: the ID of the record this one comes from, or `nil` while it has none. The
/// property's type is `Parent.ID?`. It is the only place a one-to-many or one-to-one relationship is
/// stored, and the parent's `@Reference(to:)` property is filled from it. With a sync provider it crosses
/// as a `CKRecord.Reference`, and as the record's `CKRecord.parent` when its action is `.deleteSelf`.
///
/// ```swift
/// @Reference(from: Recipe.self, action: .deleteSelf) var recipe: Recipe.ID?
/// ```
@attached(peer)
public macro Reference<Parent: Record>(from parent: Parent.Type, action: ReferenceAction) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares a stored pointer with the action `.nullify`, so deleting the parent keeps this record and
/// clears the pointer.
@attached(peer)
public macro Reference<Parent: Record>(from parent: Parent.Type) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares the records that point here, filled when you fetch.
///
/// With a key path to another type's `@Reference(from:)` property, the property is `[Child]` for
/// one-to-many or `Child?` for one-to-one. With a key path to another type's many-to-many array, the
/// property is `Set<Owner.ID>`, the IDs of the records that link here, and it is read-only.
///
/// ```swift
/// @Reference(to: \Step.recipe) var steps: [Step] = []
/// @Reference(to: \Photo.recipe) var cover: Photo?
/// @Reference(to: \Recipe.tags) var recipes: Set<Recipe.ID>
/// ```
@attached(peer)
public macro Reference<Target: Record, Value>(to keyPath: KeyPath<Target, Value>) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares the records that point here, in the order of a key path on them.
@attached(peer)
public macro Reference<Target: Record, Value, Key: Comparable>(to keyPath: KeyPath<Target, Value>, sort: KeyPath<Target, Key>) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares the records that point here, in the order of sort descriptors.
@attached(peer)
public macro Reference<Target: Record, Value>(to keyPath: KeyPath<Target, Value>, sort: [SortDescriptor<Target>]) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares a many-to-many relationship: the records of another type this one links to, as `[Target]`.
/// Each pair is stored as one small link record, so neither record holds the other's ID. Without `sort:`,
/// the records come back in the order they were linked.
///
/// ```swift
/// @Reference(to: Tag.self) var tags: [Tag] = []
/// ```
@attached(peer)
public macro Reference<Target: Record>(to type: Target.Type) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares a many-to-many relationship in the order of a key path on the linked records.
@attached(peer)
public macro Reference<Target: Record, Key: Comparable>(to type: Target.Type, sort: KeyPath<Target, Key>) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// Declares a many-to-many relationship in the order of sort descriptors.
@attached(peer)
public macro Reference<Target: Record>(to type: Target.Type, sort: [SortDescriptor<Target>]) =
    #externalMacro(module: "SwiftRecordsMacros", type: "ReferenceMacro")

/// What a stored pointer does when the record it points to is deleted. `.deleteSelf` is named after
/// `CKRecord.ReferenceAction`.
public enum ReferenceAction: String, Sendable, Hashable, Codable {
    /// Keep the record and clear its pointer when the parent is deleted or drops it.
    case nullify = "none"
    /// Delete the record when the parent is deleted or drops it.
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
        /// True for a stored pointer, `@Reference(from:)`.
        let isPointer: Bool
        /// The type a pointer points to, or `nil` for one that can point to any type, such as a link's ends.
        let pointerTarget: (any Record.Type)?
        /// What happens to this record when the one its pointer names goes.
        let action: ReferenceAction
        /// For a derived relationship, `@Reference(to:)`, where its records come from.
        let relationship: Relationship?
        /// The order a derived relationship's records come in.
        let order: RelationshipOrder?
        /// For an inverse field, the owner's many-to-many key path, such as `\Recipe.tags`.
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
            name: String, keyPath: PartialKeyPath<Root>, isPointer: Bool = false, pointerTarget: (any Record.Type)? = nil,
            action: ReferenceAction = .nullify, relationship: Relationship? = nil, order: RelationshipOrder? = nil,
            inverse: AnyKeyPath? = nil, isAsset: Bool = false, fileExtension: String = ""
        ) {
            self.name = name
            self.keyPath = keyPath
            self.isPointer = isPointer
            self.pointerTarget = pointerTarget
            self.action = action
            self.relationship = relationship
            self.order = order
            self.inverse = inverse
            self.isAsset = isAsset
            self.fileExtension = fileExtension
        }

        /// True when the field is a column of the record's own row: neither a relationship nor an inverse.
        var isStored: Bool { relationship == nil && inverse == nil }

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

        @available(*, unavailable, message: "A property that holds records needs @Reference. Use @Reference(to: \\Child.parent) when the records point here with @Reference(from:), or @Reference(to: Child.self) for many-to-many.")
        public static func field<Target: Record>(_ name: String, _ keyPath: KeyPath<Root, [Target]>) -> Field {
            fatalError()
        }

        @available(*, unavailable, message: "A property that holds a record needs @Reference. Use @Reference(to: \\Child.parent) when the record points here with @Reference(from:).")
        public static func field<Target: Record>(_ name: String, _ keyPath: KeyPath<Root, Target?>) -> Field {
            fatalError()
        }

        @available(*, unavailable, message: "A record can't hold another record directly. Declare it as optional with @Reference(to: \\Child.parent), or store its ID with @Reference(from: Child.self).")
        public static func field<Target: Record>(_ name: String, _ keyPath: KeyPath<Root, Target>) -> Field {
            fatalError()
        }

        public static func reference<Parent: Record>(
            _ name: String, _ keyPath: KeyPath<Root, UUID?>, from parent: Parent.Type, action: ReferenceAction = .nullify
        ) -> Field {
            Field(name: name, keyPath: keyPath, isPointer: true, pointerTarget: parent, action: action)
        }

        /// A pointer that can name a record of any type, with the action `.deleteSelf`.
        static func anyReference(_ name: String, _ keyPath: KeyPath<Root, UUID?>) -> Field {
            Field(name: name, keyPath: keyPath, isPointer: true, action: .deleteSelf)
        }

        /// The records whose pointer at `pointer` holds this record's ID, as `[Child]` or `Child?`.
        public static func children<Child: Record>(
            _ name: String, _ keyPath: PartialKeyPath<Root>, to pointer: KeyPath<Child, UUID?>, sortBy: [SortDescriptor<Child>] = []
        ) -> Field {
            Field(
                name: name, keyPath: keyPath, relationship: .children(Child.self, pointer: pointer),
                order: RelationshipOrder(sortBy)
            )
        }

        @available(*, unavailable, message: "This reads the other side of a many-to-many, which holds the IDs of the records that link here. Declare it as a Set of their IDs.")
        public static func children<Owner: Record>(
            _ name: String, _ keyPath: PartialKeyPath<Root>, to links: KeyPath<Owner, [Root]>, sortBy: [SortDescriptor<Owner>] = []
        ) -> Field {
            fatalError()
        }

        /// The records of `target` this one links to, one link record per pair.
        public static func links<Target: Record>(
            _ name: String, _ keyPath: PartialKeyPath<Root>, to target: Target.Type, sortBy: [SortDescriptor<Target>] = []
        ) -> Field {
            Field(name: name, keyPath: keyPath, relationship: .links(Target.self), order: RelationshipOrder(sortBy))
        }

        public static func timestamp(_ name: String, _ keyPath: KeyPath<Root, Date?>, _ kind: TimestampKind) -> Field {
            var field = Field(name: name, keyPath: keyPath)
            field.timestamp = kind
            return field
        }

        public static func asset(_ name: String, _ keyPath: KeyPath<Root, Data?>, fileExtension: String = "") -> Field {
            Field(name: name, keyPath: keyPath, isAsset: true, fileExtension: fileExtension)
        }

        /// The IDs of the records whose many-to-many array at `inverse` links here.
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

/// Where a derived relationship's records come from.
enum Relationship {
    /// The records of `type` whose pointer at `pointer` holds the owner's ID.
    case children(any Record.Type, pointer: AnyKeyPath)
    /// The records of `type` the owner links to.
    case links(any Record.Type)

    var target: any Record.Type {
        switch self {
        case .children(let type, _), .links(let type): type
        }
    }
}

/// A relationship's sort descriptors, without their record type, so the store can order any relationship's
/// records. With none, children come in ID order, which `UUID.ordered()` makes creation order, and links in
/// the order they were made.
struct RelationshipOrder: @unchecked Sendable {
    let isEmpty: Bool
    /// The `ORDER BY` terms for the related type's table, or `nil` when the order must sort in Swift.
    let columns: () -> [(column: String, descending: Bool)]?
    /// Sorts records of the related type.
    let sort: ([any Record]) -> [any Record]

    init<T: Record>(_ descriptors: [SortDescriptor<T>]) {
        let order = RecordOrder(descriptors)
        isEmpty = descriptors.isEmpty
        columns = { order.columns }
        sort = { records in order.sorted(records.compactMap { $0 as? T }) }
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
