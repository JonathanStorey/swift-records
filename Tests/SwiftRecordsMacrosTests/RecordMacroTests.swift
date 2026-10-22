import SwiftRecordsMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class RecordMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Record": RecordMacro.self, "Reference": ReferenceMacro.self,
        "Renamed": MarkerMacro.self, "Indexed": MarkerMacro.self, "Timestamp": MarkerMacro.self,
    ]

    func testGeneratesSchema() {
        assertMacroExpansion(
            """
            @Record
            public struct ToDo {
                var id = UUID()
                var title: String
                var notes: [Note] = []
                var isEmpty: Bool { title.isEmpty }
                static var sample = 1
            }
            """,
            expandedSource: """
            public struct ToDo {
                var id = UUID()
                var title: String
                var notes: [Note] = []
                var isEmpty: Bool { title.isEmpty }
                static var sample = 1
            }

            extension ToDo: Record {
                public static var schema: RecordSchema<ToDo> {
                    RecordSchema(table: "ToDo", fields: [
                        .field("id", \\ToDo.id),
                        .field("title", \\ToDo.title),
                        .field("notes", \\ToDo.notes).defaulting(([]) as [Note])
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
                @Reference(from: \\ToDo.notes) var todos: Set<ToDo.ID>
            }
            """,
            expandedSource: """
            struct Note {
                let id: UUID
                @SwiftRecords.InverseStorage var todos: Set<ToDo.ID>
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
                @Reference(to: \\ToDo.notes, action: .deleteSelf) var todo: ToDo.ID?
                @Reference(to: \\Folder.notes) var folder: Folder.ID? = nil
            }
            """,
            expandedSource: """
            struct Note {
                var id = UUID()
                var todo: ToDo.ID?
                var folder: Folder.ID? = nil
            }

            extension Note: Record {
                static var schema: RecordSchema<Note> {
                    RecordSchema(table: "Note", fields: [
                        .field("id", \\Note.id),
                        .reference("todo", \\Note.todo, to: \\ToDo.notes, action: .deleteSelf),
                        .reference("folder", \\Note.folder, to: \\Folder.notes)
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
                @Reference(to: \\ToDo.notes) var todo: ToDo.ID
            }
            """,
            expandedSource: """
            struct Note {
                var id = UUID()
                var todo: ToDo.ID
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
                    message: "A reference holds its parent's ID, or nil while it has none. Declare it as 'Parent.ID?'",
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
                @Timestamp(.created) var created: Date?
                @Timestamp var modified: Date?
                @Timestamp(TimestampKind.synced) var synced: Date?
                @Timestamp var wrong: Date
            }
            """,
            expandedSource: """
            struct Entry {
                var id = UUID()
                @SwiftRecords.TimestampStorage var created: Date?
                @SwiftRecords.TimestampStorage var modified: Date?
                @SwiftRecords.TimestampStorage var synced: Date?
                var wrong: Date
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
                DiagnosticSpec(message: "A @Timestamp property must be declared as 'Date?'", line: 7, column: 20),
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
                @Reference(from: \\ToDo.notes) var todos: [ToDo.ID] = []
                @Reference(from: \\ToDo.tags) var tagged: Set<ToDo.ID> = []
            }
            """,
            expandedSource: """
            struct Note {
                var id = UUID()
                var todos: [ToDo.ID] = []
                var tagged: Set<ToDo.ID> = []
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
                    message: "An inverse holds the IDs of the records that link here, in no order. Declare it as 'Set<Owner.ID>'",
                    line: 4, column: 39
                ),
                DiagnosticSpec(
                    message: "An inverse is read-only and filled by the container, so it takes no initial value. Remove '= []'",
                    line: 5, column: 59
                ),
            ],
            macros: macros
        )
    }

    func testMarkersWarnOutsideARecord() {
        assertMacroExpansion(
            """
            struct Settings {
                @Indexed var name = ""
                @Timestamp var updated: Date?
                @Reference(to: \\Folder.items) var folder: Folder.ID?
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
                DiagnosticSpec(message: "@Timestamp has no effect outside a @Record struct", line: 3, column: 5, severity: .warning),
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
                var _version = 1
                var rowid = 0
            }
            """,
            expandedSource: """
            struct Draft {
                var id = UUID()
                var _version = 1
                var rowid = 0
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
                DiagnosticSpec(message: "'_version' is a name SwiftRecords uses for its own bookkeeping. Choose another name", line: 4, column: 9),
                DiagnosticSpec(message: "'rowid' is a name SwiftRecords uses for its own bookkeeping. Choose another name", line: 5, column: 9),
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
