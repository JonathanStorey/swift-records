import SwiftRecordsMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class RecordMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Record": RecordMacro.self, "Reference": ReferenceMacro.self,
        "Renamed": MarkerMacro.self, "Indexed": MarkerMacro.self, "Timestamped": MarkerMacro.self,
    ]

    func testGeneratesSchema() {
        assertMacroExpansion(
            """
            @Record
            public struct ToDo {
                var id = UUID()
                var title: String
                var labels: [String] = []
                var isEmpty: Bool { title.isEmpty }
                static var sample = 1
            }
            """,
            expandedSource: """
            public struct ToDo {
                var id = UUID()
                var title: String
                var labels: [String] = []
                var isEmpty: Bool { title.isEmpty }
                static var sample = 1

                public typealias ID = UUID
            }

            extension ToDo: Record {
                public static var schema: RecordSchema<ToDo> {
                    RecordSchema(table: "ToDo", fields: [
                        .field("id", \\ToDo.id),
                        .field("title", \\ToDo.title),
                        .field("labels", \\ToDo.labels).defaulting(([]) as [String])
                    ])
                }
            }
            """,
            macros: macros
        )
    }

    func testGeneratesInverse() {
        assertMacroExpansion(
            """
            @Record
            struct Note {
                let id: UUID
                @Reference(to: \\ToDo.notes) var todos: Set<ToDo.ID>
            }
            """,
            expandedSource: """
            struct Note {
                let id: UUID
                @SwiftRecords.InverseStorage var todos: Set<ToDo.ID>

                typealias ID = UUID
            }

            extension Note: Record {
                static var schema: RecordSchema<Note> {
                    RecordSchema(table: "Note", fields: [
                        .field("id", \\Note.id),
                        .inverse("todos", \\Note.todos, of: \\ToDo.notes)
                    ])
                }
            }
            """,
            macros: macros
        )
    }

    func testGeneratesReferences() {
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id = UUID()
                @Reference(from: ToDo.self, action: .deleteSelf) var todo: ToDo.ID?
                @Reference(from: Folder.self) var folder: Folder.ID? = nil
            }
            """,
            expandedSource: """
            struct Note {
                var id = UUID()
                var todo: ToDo.ID?
                var folder: Folder.ID? = nil

                typealias ID = UUID
            }

            extension Note: Record {
                static var schema: RecordSchema<Note> {
                    RecordSchema(table: "Note", fields: [
                        .field("id", \\Note.id),
                        .reference("todo", \\Note.todo, from: ToDo.self, action: .deleteSelf),
                        .reference("folder", \\Note.folder, from: Folder.self)
                    ])
                }
            }
            """,
            macros: macros
        )
    }

    func testReferencesMustBeOptional() {
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id = UUID()
                @Reference(from: ToDo.self) var todo: ToDo.ID
            }
            """,
            expandedSource: """
            struct Note {
                var id = UUID()
                var todo: ToDo.ID

                typealias ID = UUID
            }

            extension Note: Record {
                static var schema: RecordSchema<Note> {
                    RecordSchema(table: "Note", fields: [
                        .field("id", \\Note.id)
                    ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "A @Reference(from:) property holds its parent's ID, or nil while it has none. Declare it as 'ToDo.ID?'",
                    line: 4, column: 37
                ),
            ],
            macros: macros
        )
    }

    func testRejectsClasses() {
        assertMacroExpansion(
            """
            @Record
            class Thing {
                var id = 0
            }
            """,
            expandedSource: """
            class Thing {
                var id = 0
            }
            """,
            diagnostics: [DiagnosticSpec(message: "@Record can only be applied to a struct", line: 1, column: 1)],
            macros: macros
        )
    }

    func testRejectsNonUUIDIDs() {
        assertMacroExpansion(
            """
            @Record
            struct Counter {
                var id: Int
                var count = 0
            }
            """,
            expandedSource: """
            struct Counter {
                var id: Int
                var count = 0

                typealias ID = UUID
            }

            extension Counter: Record {
                static var schema: RecordSchema<Counter> {
                    RecordSchema(table: "Counter", fields: [
                        .field("id", \\Counter.id),
                        .field("count", \\Counter.count).defaulting(0)
                    ])
                }
            }
            """,
            diagnostics: [DiagnosticSpec(message: "A record's 'id' must be a 'UUID'", line: 3, column: 9)],
            macros: macros
        )
    }

    func testRejectsLetsWithInitialValues() {
        assertMacroExpansion(
            """
            @Record
            struct Tag {
                let id = UUID()
                let name: String
            }
            """,
            expandedSource: """
            struct Tag {
                let id = UUID()
                let name: String

                typealias ID = UUID
            }

            extension Tag: Record {
                static var schema: RecordSchema<Tag> {
                    RecordSchema(table: "Tag", fields: [
                        .field("name", \\Tag.name)
                    ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'id' is a 'let' with an initial value, which decoding skips, so every fetch would give it a new value. Declare it with 'var'",
                    line: 3, column: 5,
                    fixIts: [FixItSpec(message: "Change 'let' to 'var'")]
                ),
            ],
            macros: macros
        )
    }

    func testGeneratesDefaultsNamesRenamesAndIndexes() {
        assertMacroExpansion(
            """
            @Record("Recipe")
            struct Dish {
                var id = UUID()
                @Renamed(from: "minutes", "time") var duration: Double = 5
                @Indexed var name = ""
                var due: Date? = nil
                var status: Status = .draft
            }
            """,
            expandedSource: """
            struct Dish {
                var id = UUID()
                var duration: Double = 5
                var name = ""
                var due: Date? = nil
                var status: Status = .draft

                typealias ID = UUID
            }

            extension Dish: Record {
                static var schema: RecordSchema<Dish> {
                    RecordSchema(table: "Recipe", fields: [
                        .field("id", \\Dish.id),
                        .field("duration", \\Dish.duration).defaulting((5) as Double).renamed(from: "minutes", "time"),
                        .field("name", \\Dish.name).defaulting("").indexed(),
                        .field("due", \\Dish.due),
                        .field("status", \\Dish.status).defaulting((.draft) as Status)
                    ])
                }
            }
            """,
            macros: macros
        )
    }

    func testRejectsGenericStructs() {
        assertMacroExpansion(
            """
            @Record
            struct Box<T: Codable & Sendable> {
                var id = UUID()
                var value: T
            }
            """,
            expandedSource: """
            struct Box<T: Codable & Sendable> {
                var id = UUID()
                var value: T

                typealias ID = UUID
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: "@Record can't be applied to a generic struct, because each specialization would need its own fixed table name. Use a concrete struct, or store the generic value in a Codable property of one",
                line: 1, column: 1
            )],
            macros: macros
        )
    }

    func testGeneratesAssetField() {
        assertMacroExpansion(
            """
            @Record
            struct Photo {
                var id = UUID()
                @Asset(fileExtension: "jpg") var image: Data?
                @Asset var raw: Data?
            }
            """,
            expandedSource: """
            struct Photo {
                var id = UUID()
                @Asset(fileExtension: "jpg") var image: Data?
                @Asset var raw: Data?

                typealias ID = UUID
            }

            extension Photo: Record {
                static var schema: RecordSchema<Photo> {
                    RecordSchema(table: "Photo", fields: [
                        .field("id", \\Photo.id),
                        .asset("image", \\Photo.image, fileExtension: "jpg"),
                        .asset("raw", \\Photo.raw)
                    ])
                }
            }
            """,
            macros: macros
        )
    }

    func testGeneratesTimestampFields() {
        assertMacroExpansion(
            """
            @Record
            struct Entry {
                var id = UUID()
                @Timestamped(.created) var created: Date?
                @Timestamped var modified: Date?
                @Timestamped(TimestampKind.synced) var synced: Date?
                @Timestamped var wrong: Date
            }
            """,
            expandedSource: """
            struct Entry {
                var id = UUID()
                @SwiftRecords.TimestampStorage var created: Date?
                @SwiftRecords.TimestampStorage var modified: Date?
                @SwiftRecords.TimestampStorage var synced: Date?
                var wrong: Date

                typealias ID = UUID
            }

            extension Entry: Record {
                static var schema: RecordSchema<Entry> {
                    RecordSchema(table: "Entry", fields: [
                        .field("id", \\Entry.id),
                        .timestamp("created", \\Entry.created, .created),
                        .timestamp("modified", \\Entry.modified, .modified),
                        .timestamp("synced", \\Entry.synced, .synced)
                    ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "A @Timestamped property must be declared as 'Date?'", line: 7, column: 22),
            ],
            macros: macros
        )
    }

    func testInversesMustBeSets() {
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id = UUID()
                @Reference(to: \\ToDo.notes) var todos: [ToDo.ID] = []
                @Reference(to: \\ToDo.tags) var tagged: Set<ToDo.ID> = []
            }
            """,
            expandedSource: """
            struct Note {
                var id = UUID()
                var todos: [ToDo.ID] = []
                var tagged: Set<ToDo.ID> = []

                typealias ID = UUID
            }

            extension Note: Record {
                static var schema: RecordSchema<Note> {
                    RecordSchema(table: "Note", fields: [
                        .field("id", \\Note.id)
                    ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Reference(to:) holds the records that point here: '[ToDo]' for many or 'ToDo?' for one. The other side of a many-to-many is 'Set<ToDo.ID>'",
                    line: 4, column: 37
                ),
                DiagnosticSpec(
                    message: "This side of a many-to-many is read-only and filled by the container, so it takes no initial value. Remove '= []'",
                    line: 5, column: 57
                ),
            ],
            macros: macros
        )
    }

    func testGeneratesChildrenAndLinks() {
        assertMacroExpansion(
            """
            @Record
            struct Recipe {
                var id = UUID()
                @Reference(to: \\Step.recipe, sort: \\.position) var steps: [Step] = []
                @Reference(to: \\Photo.recipe) var cover: Photo? = nil
                @Reference(to: Tag.self) var tags: [Tag] = []
                @Reference(to: Cook.self, sort: [SortDescriptor(\\Cook.name)]) var cooks: [Cook] = []
            }
            """,
            expandedSource: """
            struct Recipe {
                var id = UUID()
                @SwiftRecords.RelationshipStorage var steps: [Step] = []
                @SwiftRecords.RelationshipStorage var cover: Photo? = nil
                @SwiftRecords.RelationshipStorage var tags: [Tag] = []
                @SwiftRecords.RelationshipStorage var cooks: [Cook] = []

                typealias ID = UUID
            }

            extension Recipe: Record {
                static var schema: RecordSchema<Recipe> {
                    RecordSchema(table: "Recipe", fields: [
                        .field("id", \\Recipe.id),
                        .children("steps", \\Recipe.steps, to: \\Step.recipe, sortBy: [SortDescriptor(\\Step.position)]),
                        .children("cover", \\Recipe.cover, to: \\Photo.recipe),
                        .links("tags", \\Recipe.tags, to: Tag.self),
                        .links("cooks", \\Recipe.cooks, to: Cook.self, sortBy: [SortDescriptor(\\Cook.name)])
                    ])
                }
            }
            """,
            macros: macros
        )
    }

    func testRejectsMisspelledRelationships() {
        assertMacroExpansion(
            """
            @Record
            struct Recipe {
                var id = UUID()
                @Reference(from: \\Book.recipes) var book: Book.ID?
                @Reference(to: Tag.self) var tags: Set<Tag> = []
                @Reference(to: \\Step.recipe) var steps: Set<Step.ID>
                @Reference(to: \\Note.recipe) var note: Note
                @Reference(to: \\Cook.recipes, sort: \\.name) var cooks: Set<Cook.ID>
                @Reference var owner: Person.ID?
            }
            """,
            expandedSource: """
            struct Recipe {
                var id = UUID()
                var book: Book.ID?
                var tags: Set<Tag> = []
                @SwiftRecords.InverseStorage var steps: Set<Step.ID>
                var note: Note
                @SwiftRecords.InverseStorage var cooks: Set<Cook.ID>
                var owner: Person.ID?

                typealias ID = UUID
            }

            extension Recipe: Record {
                static var schema: RecordSchema<Recipe> {
                    RecordSchema(table: "Recipe", fields: [
                        .field("id", \\Recipe.id),
                        .inverse("steps", \\Recipe.steps, of: \\Step.recipe)
                    ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference(from:) names the type this record comes from, such as 'Recipe.self'", line: 4, column: 22),
                DiagnosticSpec(message: "A many-to-many relationship holds the records it links to. Declare it as '[Tag]'", line: 5, column: 34),
                DiagnosticSpec(
                    message: "@Reference(to:) holds the records that point here: '[Note]' for many or 'Note?' for one. The other side of a many-to-many is 'Set<Note.ID>'",
                    line: 7, column: 38
                ),
                DiagnosticSpec(message: "A set of IDs has no order, so it takes no 'sort:'", line: 8, column: 41),
                DiagnosticSpec(message: "@Reference needs 'from:' or 'to:'", line: 9, column: 5),
            ],
            macros: macros
        )
    }

    func testMarkersWarnOutsideARecord() {
        assertMacroExpansion(
            """
            struct Settings {
                @Indexed var name = ""
                @Timestamped var updated: Date?
                @Reference(from: Folder.self) var folder: Folder.ID?
            }
            """,
            expandedSource: """
            struct Settings {
                var name = ""
                var updated: Date?
                var folder: Folder.ID?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Indexed has no effect outside a @Record struct", line: 2, column: 5, severity: .warning),
                DiagnosticSpec(message: "@Timestamped has no effect outside a @Record struct", line: 3, column: 5, severity: .warning),
                DiagnosticSpec(message: "@Reference has no effect outside a @Record struct", line: 4, column: 5, severity: .warning),
            ],
            macros: macros
        )
    }

    func testRejectsAssetsThatAreNotOptionalData() {
        assertMacroExpansion(
            """
            @Record
            struct Photo {
                var id = UUID()
                @Asset var image: Data
                @Asset var name: String?
            }
            """,
            expandedSource: """
            struct Photo {
                var id = UUID()
                @Asset var image: Data
                @Asset var name: String?

                typealias ID = UUID
            }

            extension Photo: Record {
                static var schema: RecordSchema<Photo> {
                    RecordSchema(table: "Photo", fields: [
                        .field("id", \\Photo.id)
                    ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "An @Asset property must be declared as 'Data?'", line: 4, column: 16),
                DiagnosticSpec(message: "An @Asset property must be declared as 'Data?'", line: 5, column: 16),
            ],
            macros: macros
        )
    }
    func testRejectsReservedPropertyNames() {
        assertMacroExpansion(
            """
            @Record
            struct Draft {
                var id = UUID()
                var oid = 1
                var rowid = 0
            }
            """,
            expandedSource: """
            struct Draft {
                var id = UUID()
                var oid = 1
                var rowid = 0

                typealias ID = UUID
            }

            extension Draft: Record {
                static var schema: RecordSchema<Draft> {
                    RecordSchema(table: "Draft", fields: [
                        .field("id", \\Draft.id)
                    ])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'oid' is SQLite's name for a table's row ID. Choose another name", line: 4, column: 9),
                DiagnosticSpec(message: "'rowid' is SQLite's name for a table's row ID. Choose another name", line: 5, column: 9),
            ],
            macros: macros
        )
    }

    func testRejectsInvalidStoredNames() {
        for name in ["\"Recipe.steps\"", "\"9lives\"", "\"\"", "someConstant"] {
            assertMacroExpansion(
                """
                @Record(\(name))
                struct Dish {
                    var id = UUID()
                }
                """,
                expandedSource: """
                struct Dish {
                    var id = UUID()

                    typealias ID = UUID
                }
                """,
                diagnostics: [DiagnosticSpec(
                    message: "@Record(_:) takes a string literal of letters, digits and underscores that doesn't start with a digit",
                    line: 1, column: 1
                )],
                macros: macros
            )
        }
    }

    func testNestedTypesNeedAStoredName() {
        assertMacroExpansion(
            """
            enum Pantry {
                @Record
                struct Item {
                    var id = UUID()
                }
            }
            """,
            expandedSource: """
            enum Pantry {
                struct Item {
                    var id = UUID()

                    typealias ID = UUID
                }
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: "A nested @Record type needs @Record(_:), because it's stored under its simple name 'Item', which another type could also use",
                line: 2, column: 5
            )],
            macros: macros
        )
        assertMacroExpansion(
            """
            enum Pantry {
                @Record("PantryItem")
                struct Item {
                    var id = UUID()
                }
            }
            """,
            expandedSource: """
            enum Pantry {
                struct Item {
                    var id = UUID()

                    typealias ID = UUID
                }
            }

            extension Pantry.Item: Record {
                static var schema: RecordSchema<Pantry.Item> {
                    RecordSchema(table: "PantryItem", fields: [
                        .field("id", \\Pantry.Item.id)
                    ])
                }
            }
            """,
            macros: macros
        )
    }
}
