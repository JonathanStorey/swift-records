import Foundation
import SwiftRecords
import Testing

@Record
struct Person {
    var id = UUID.ordered()
    var name: String
    @Reference(from: \ToDo.owner) var todoIDs: Set<ToDo.ID>
}

@Record
struct ToDo {
    var id = UUID.ordered()
    var title: String
    var done = false
    var priority = 0
    var due: Date?
    var owner: Person?
    var notes: [Note] = []
    var subtasks: [Subtask] = []
    var tags: [String] = []
}

@Record
struct Note {
    var id = UUID.ordered()
    var text: String
    @Reference(from: \ToDo.notes) var todos: Set<ToDo.ID>
}

@Record
struct Subtask {
    var id = UUID.ordered()
    var title: String
    @Reference(to: \ToDo.subtasks, action: .deleteSelf) var todo: ToDo.ID?
    @Reference(to: \Folder.items, action: .deleteSelf) var folder: Folder.ID?
}

@Record
struct Folder {
    var id = UUID.ordered()
    var name: String
    var items: [Subtask] = []
}

@Suite struct RecordContainerTests {
    let store = try! RecordContainer(inMemory: true)

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
        // A person can own many to-dos, so unlinking keeps them.
        #expect(try store.fetch(Person.self).map(\.name) == ["Sam"])
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

    @Test func loadsInverseAsASet() throws {
        let note = Note(text: "Shared")
        let first = ToDo(title: "First", notes: [note])
        let second = ToDo(title: "Second", notes: [note])
        let other = ToDo(title: "Other", notes: [Note(text: "Own")])
        try store.save([second, first, other])

        let fetched = try #require(try store.fetch(Note.self, id: note.id))
        #expect(fetched.todos == [first.id, second.id])
        // A set of IDs loads sorted by ID.
        #expect(try store.fetch(ToDo.self, ids: fetched.todos).map(\.title) == ["First", "Second"])

        let firstID = first.id
        #expect(try store.fetch(Note.self, where: #Predicate { $0.todos.contains(firstID) }).map(\.text) == ["Shared"])
        let otherID = other.id
        #expect(try store.fetch(Note.self, where: #Predicate { !$0.todos.contains(otherID) }).map(\.text) == ["Shared"])
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

    @Test func noneKeepsRelatedRecords() throws {
        let todo = ToDo(title: "With notes", notes: [Note(text: "Keep me")])
        try store.save(todo)
        try store.delete(todo)

        let notes = try store.fetch(Note.self)
        #expect(notes.map(\.text) == ["Keep me"])
        #expect(notes[0].todos.isEmpty)
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

    @Test func searchesInsideRelationships() throws {
        try store.save([
            ToDo(title: "Greet", notes: [Note(text: "hello world"), Note(text: "other")]),
            ToDo(title: "Quiet", notes: [Note(text: "shh")]),
            ToDo(title: "Empty"),
        ])
        let matches = try store.fetch(ToDo.self, where: #Predicate { todo in
            todo.notes.contains { $0.text == "hello world" }
        })
        #expect(matches.map(\.title) == ["Greet"])

        let none = try store.fetch(ToDo.self, where: #Predicate { todo in
            !todo.notes.contains { $0.text != "" }
        })
        #expect(none.map(\.title) == ["Empty"])
    }

    @Test func relationshipSearchBeforeAnyLinksExist() throws {
        try store.save(Folder(name: "Inbox"))
        let matches = try store.fetch(Folder.self, where: #Predicate { folder in
            folder.items.contains { $0.title == "x" }
        })
        #expect(matches.isEmpty)
    }

    @Test func unsupportedPredicatesFallBackToMemory() throws {
        try store.save([
            ToDo(title: "Short"),
            ToDo(title: "A much longer title"),
        ])
        let long = try store.fetch(ToDo.self, where: #Predicate { $0.title.count > 10 })
        #expect(long.map(\.title) == ["A much longer title"])
    }

    @Test func fetchesSortedByID() throws {
        let todos = (0..<20).map { ToDo(title: "T\($0)") }
        try store.save(todos)
        let sorted = todos.map(\.id).sorted { $0.uuidString < $1.uuidString }
        #expect(try store.fetch(ToDo.self).map(\.id) == sorted)
        #expect(try store.fetch(ToDo.self, ids: Set(sorted)).map(\.id) == sorted)
    }

    @Test func persistsToDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let todo = ToDo(title: "Saved", notes: [Note(text: "On disk")])
        do {
            let store = try RecordContainer(directory: directory)
            try store.save(todo)
        }
        let reopened = try RecordContainer(directory: directory)
        let fetched = try #require(try reopened.fetch(ToDo.self, id: todo.id))
        #expect(fetched.notes.map(\.text) == ["On disk"])
        // Delete rules survive a relaunch because they are stored with the schema.
        try reopened.delete(todo)
        #expect(try reopened.fetch(Note.self).count == 1)
    }
}
