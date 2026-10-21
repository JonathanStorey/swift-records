import SwiftRecordsMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class RecordMacroTests: XCTestCase {
    let macros: [String: Macro.Type] = ["Record": RecordMacro.self, "Reference": ReferenceMacro.self]

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
                        .field("notes", \\ToDo.notes, deleteRule: .none)
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
                let id: Int
                @Reference(from: \\ToDo.notes) var todos: [ToDo.ID] = []
            }
            """,
            expandedSource: """
            struct Note {
                let id: Int
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

    func testGeneratesAssetField() {
        assertMacroExpansion(
            """
            @Record
            struct Photo {
                var id = UUID()
                var image: Asset?
            }
            """,
            expandedSource: """
            struct Photo {
                var id = UUID()
                var image: Asset?
            }

            extension Photo: Record {
                static var schema: RecordSchema<Photo> {
                    RecordSchema(table: "Photo", fields: [
                        .field("id", \\Photo.id),
                        .asset("image", \\Photo.image)
                    ])
                }
            }
            """,
            macros: macros
        )
    }

    func testRejectsNonOptionalAssets() {
        assertMacroExpansion(
            """
            @Record
            struct Photo {
                var id = UUID()
                var image: Asset
                var gallery: [Asset] = []
            }
            """,
            expandedSource: """
            struct Photo {
                var id = UUID()
                var image: Asset
                var gallery: [Asset] = []
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
                DiagnosticSpec(message: "An Asset property must be optional: declare it as 'Asset?'", line: 4, column: 9),
                DiagnosticSpec(message: "An Asset property must be optional: declare it as 'Asset?'", line: 5, column: 9),
            ],
            macros: macros
        )
    }
}
