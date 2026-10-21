import SwiftRecordsMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class RecordMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = [
        "Record": RecordMacro.self, "Reference": ReferenceMacro.self,
        "Renamed": MarkerMacro.self, "Indexed": MarkerMacro.self,
    ]

    func testGeneratesSchema() {
        assertMacroExpansion(
            """
            @Record
            public struct ToDo {
                var id = UUID()
                var title: String
                @Reference(deleteRule: .none) var notes: [Note] = []
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
                        .field("notes", \\ToDo.notes, deleteRule: .none).defaulting(([]) as [Note])
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
                @Reference(from: \\ToDo.notes) var todos: [ToDo.ID] = []
            }
            """,
            expandedSource: """
            struct Note {
                let id: UUID
                var todos: [ToDo.ID] = []
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
            @Record(name: "Recipe")
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
}
