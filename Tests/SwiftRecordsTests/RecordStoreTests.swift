import Foundation
import SwiftRecords
import Testing

@Record
struct Person {
    var id = UUID()
    var name: String
}

@Record
struct ToDo {
    var id = UUID()
    var title: String
    var done = false
    var priority = 0
    var due: Date?
    var owner: Person?
    @Reference(deleteRule: .nullify) var notes: [Note] = []
    var subtasks: [Subtask] = []
    var tags: [String] = []
}

@Record
struct Note {
    var id = UUID()
    var text: String
    @Reference(from: \ToDo.notes) var todos: [ToDo.ID] = []
}

@Record
struct Subtask {
    var id = UUID()
    var title: String
}

@Record
struct Folder {
    var id: Int
    var name: String
    @Reference(deleteRule: .deny) var items: [Subtask] = []
}

@Suite struct RecordStoreTests {
    let store = try! RecordStore()

    @Test func roundTripsScalarsAndJSON() throws {
        let due = Date(timeIntervalSince1970: 1_000_000)
        let todo = ToDo(title: "Paint fence", priority: 2, due: due, tags: ["home", "weekend"])
        try store.save(todo)

        let fetched = try #require(try store.fetch(ToDo.self, id: todo.id))
        #expect(fetched.title == "Paint fence")
        #expect(fetched.priority == 2)
        #expect(fetched.due == due)
        #expect(fetched.tags == ["home", "weekend"])
        #expect(fetched.owner == nil)
    }

    @Test func clearsOptionalsSetToNil() throws {
        var todo = ToDo(title: "A", due: .now, owner: Person(name: "Sam"))
        try store.save(todo)
        todo.due = nil
        todo.owner = nil
        try store.save(todo)

        let fetched = try #require(try store.fetch(ToDo.self, id: todo.id))
        #expect(fetched.due == nil)
        #expect(fetched.owner == nil)
        // The person was cascaded once nothing referenced it.
        #expect(try store.fetch(Person.self).isEmpty)
    }

    @Test func savesNestedRecordsInOrder() throws {
        let notes = (1...5).map { Note(text: "Note \($0)") }
        let todo = ToDo(title: "Groceries", owner: Person(name: "Sam"), notes: notes.reversed())
        try store.save(todo)

        let fetched = try #require(try store.fetch(ToDo.self, id: todo.id))
        #expect(fetched.owner?.name == "Sam")
        #expect(fetched.notes.map(\.text) == notes.reversed().map(\.text))
        #expect(try store.fetch(Note.self).count == 5)
    }

    @Test func loadsInverseInOrder() throws {
        let note = Note(text: "Shared")
        let first = ToDo(title: "First", notes: [note])
        let second = ToDo(title: "Second", notes: [note])
        try store.save([first, second])

        var fetched = try #require(try store.fetch(Note.self, id: note.id))
        #expect(fetched.todos == [first.id, second.id])

        fetched.todos.reverse()
        try store.save(fetched)
        let reordered = try #require(try store.fetch(Note.self, id: note.id))
        #expect(reordered.todos == [second.id, first.id])
        #expect(try store.fetch(ToDo.self, ids: reordered.todos).map(\.title) == ["Second", "First"])
    }

    @Test func cascadeIsTheDefault() throws {
        let shared = Subtask(title: "Shared")
        let first = ToDo(title: "First", subtasks: [Subtask(title: "Only mine"), shared])
        let second = ToDo(title: "Second", subtasks: [shared])
        try store.save([first, second])

        try store.delete(first)
        // "Only mine" is gone; "Shared" survives because the second ToDo still holds it.
        #expect(try store.fetch(Subtask.self).map(\.title) == ["Shared"])

        try store.delete(second)
        #expect(try store.fetch(Subtask.self).isEmpty)
    }

    @Test func removingFromArrayCascades() throws {
        var todo = ToDo(title: "List", subtasks: [Subtask(title: "Keep"), Subtask(title: "Drop")])
        try store.save(todo)
        todo.subtasks.removeLast()
        try store.save(todo)
        #expect(try store.fetch(Subtask.self).map(\.title) == ["Keep"])
    }

    @Test func nullifyKeepsRelatedRecords() throws {
        let todo = ToDo(title: "With notes", notes: [Note(text: "Keep me")])
        try store.save(todo)
        try store.delete(todo)

        let notes = try store.fetch(Note.self)
        #expect(notes.map(\.text) == ["Keep me"])
        #expect(notes[0].todos.isEmpty)
    }

    @Test func denyBlocksDelete() throws {
        let folder = Folder(id: 1, name: "Inbox", items: [Subtask(title: "Item")])
        try store.save(folder)
        #expect(throws: RecordStoreError.deleteDenied(table: "Folder", field: "items")) {
            try store.delete(folder)
        }
        #expect(try store.fetch(Folder.self, id: 1) != nil)

        var emptied = folder
        emptied.items = []
        try store.save(emptied)
        try store.delete(emptied)
        #expect(try store.fetch(Folder.self, id: 1) == nil)
    }

    @Test func predicatesRunAsSQL() throws {
        try store.save([
            ToDo(title: "Alpha", done: true, priority: 1),
            ToDo(title: "Beta", priority: 3),
            ToDo(title: "Gamma", priority: 5, due: .now),
        ])

        let open = try store.fetch(ToDo.self, where: #Predicate { !$0.done && $0.priority >= 3 })
        #expect(Set(open.map(\.title)) == ["Beta", "Gamma"])

        let undated = try store.fetch(ToDo.self, where: #Predicate { $0.due == nil })
        #expect(Set(undated.map(\.title)) == ["Alpha", "Beta"])

        let picked = try store.fetch(ToDo.self, where: #Predicate { [1, 5].contains($0.priority) })
        #expect(Set(picked.map(\.title)) == ["Alpha", "Gamma"])

        #if canImport(Darwin)
        let matched = try store.fetch(ToDo.self, where: #Predicate { $0.title.localizedStandardContains("ALP") })
        #expect(matched.map(\.title) == ["Alpha"])
        #endif

        let titles = ["Alpha", "Beta"]
        let byTitle = try store.fetch(ToDo.self, where: #Predicate { titles.contains($0.title) })
        #expect(Set(byTitle.map(\.title)) == ["Alpha", "Beta"])
    }

    @Test func unsupportedPredicatesFallBackToMemory() throws {
        try store.save([
            ToDo(title: "Short"),
            ToDo(title: "A much longer title"),
        ])
        let long = try store.fetch(ToDo.self, where: #Predicate { $0.title.count > 10 })
        #expect(long.map(\.title) == ["A much longer title"])
    }

    @Test func sortsWithDescriptorsOrStoredOrder() throws {
        let todos = [ToDo(title: "B", priority: 2), ToDo(title: "C", priority: 1), ToDo(title: "A", priority: 3)]
        try store.save(todos)

        #expect(try store.fetch(ToDo.self).map(\.title) == ["B", "C", "A"])
        #expect(try store.fetch(ToDo.self, sortBy: [SortDescriptor(\.title)]).map(\.title) == ["A", "B", "C"])
        #expect(try store.fetch(ToDo.self, sortBy: [SortDescriptor(\.priority, order: .reverse)]).map(\.title) == ["A", "B", "C"])

        try store.setOrder([todos[2].id, todos[0].id, todos[1].id], for: ToDo.self)
        #expect(try store.fetch(ToDo.self).map(\.title) == ["A", "B", "C"])
    }

    @Test func persistsToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let todo = ToDo(title: "Saved", notes: [Note(text: "On disk")])
        do {
            let store = try RecordStore(url: url)
            try store.save(todo)
        }
        let reopened = try RecordStore(url: url)
        let fetched = try #require(try reopened.fetch(ToDo.self, id: todo.id))
        #expect(fetched.notes.map(\.text) == ["On disk"])
        // Delete rules survive a relaunch because they are stored with the schema.
        try reopened.delete(todo)
        #expect(try reopened.fetch(Note.self).count == 1)
    }
}
