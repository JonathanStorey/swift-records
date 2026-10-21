import Foundation
import SwiftRecords
import Testing

@Suite struct PagingTests {
    let container = try! RecordContainer(zone: .inMemory)

    init() throws {
        try container.save((0..<10).map { ToDo(title: "Item \($0)", priority: $0 % 3) })
    }

    @Test func pagesKeepTheirPositions() throws {
        let page = try container.fetch(ToDo.self, limit: 3, offset: 4)
        #expect(page.indices == 4..<7)
        #expect(page[4].title == "Item 4")
        #expect(page.map(\.title) == ["Item 4", "Item 5", "Item 6"])

        let last = try container.fetch(ToDo.self, limit: 5, offset: 8)
        #expect(last.indices == 8..<10)
        #expect(try container.fetch(ToDo.self, limit: 5, offset: 20).isEmpty)
    }

    @Test func pagesFilterAndSort() throws {
        let sql = try container.fetch(ToDo.self, where: #Predicate { $0.priority == 0 }, limit: 2, offset: 1)
        #expect(sql.map(\.title) == ["Item 3", "Item 6"])

        let inMemory = try container.fetch(ToDo.self, where: #Predicate { $0.title.count > 0 && $0.priority == 0 }, limit: 2, offset: 1)
        #expect(inMemory.map(\.title) == ["Item 3", "Item 6"])

        let sorted = try container.fetch(ToDo.self, sortBy: [SortDescriptor(\.title, order: .reverse)], limit: 2)
        #expect(sorted.map(\.title) == ["Item 9", "Item 8"])
    }

    @Test func countsInSQLOrMemory() throws {
        #expect(try container.count(ToDo.self) == 10)
        #expect(try container.count(ToDo.self, where: #Predicate { $0.priority == 1 }) == 3)
        #expect(try container.count(ToDo.self, where: #Predicate { $0.title.count > 6 }) == 0)
        #expect(try container.count(Note.self) == 0)
    }

    @Test func batchLoadsNestedAndInverseRelationships() throws {
        let shared = Note(text: "shared")
        let todos = (0..<3).map { index in
            ToDo(title: "Batch \(index)", notes: [Note(text: "own \(index)"), shared], subtasks: [Subtask(title: "S\(index)")])
        }
        try container.save(todos)

        let fetched = try container.fetch(ToDo.self, where: #Predicate { $0.title.starts(with: "Batch") })
        #expect(fetched.map { $0.notes.map(\.text) } == [["own 0", "shared"], ["own 1", "shared"], ["own 2", "shared"]])
        #expect(fetched.map { $0.subtasks.map(\.title) } == [["S0"], ["S1"], ["S2"]])

        let note = try #require(try container.fetch(Note.self, id: shared.id))
        #expect(note.todos == todos.map(\.id))
    }
}
