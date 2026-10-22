import Foundation
import SwiftRecords
import Testing

@Suite struct ChangeLogTests {
    let container = try! RecordContainer(zone: .inMemory)

    private func version<R: Record>(_ record: R) throws -> Int? {
        try container.metadata(R.self, id: record.id)?.version
    }

    @Test func savingBumpsTheVersionOnlyWhenSomethingChanged() throws {
        var todo = ToDo(title: "Write")
        try container.save(todo)
        #expect(try version(todo) == 1)
        #expect(try container.metadata(ToDo.self, id: todo.id)?.modified != nil)

        try container.save(todo)
        #expect(try version(todo) == 1)

        todo.title = "Rewrite"
        try container.save(todo)
        #expect(try version(todo) == 2)
    }

    @Test func aTransactionBumpsEachRecordOnce() throws {
        var todo = ToDo(title: "A")
        try container.transaction {
            try container.save(todo)
            todo.title = "B"
            try container.save(todo)
        }
        #expect(try version(todo) == 1)
    }

    @Test func linkingChangesTheOwnerOnly() throws {
        let note = Note(text: "Shared")
        var first = ToDo(title: "First")
        let second = ToDo(title: "Second", notes: [note])
        try container.save([first, second])
        #expect(try version(second) == 1)

        first.notes = [note]
        try container.save(first)
        #expect(try version(first) == 2)
        #expect(try version(note) == 1)

        // The inverse is read from the owners' links, so saving the target leaves them alone.
        let fetched = try #require(try container.fetch(Note.self, id: note.id))
        try container.save(fetched)
        #expect(try version(note) == 1)
        #expect(try version(first) == 2)
        #expect(try container.fetch(Note.self, id: note.id)?.todos == [first.id, second.id])
    }

    @Test func logKeepsOneEntryPerRecordInOrder() throws {
        var a = Person(name: "A")
        let b = Person(name: "B")
        try container.save(a)
        try container.save(b)
        a.name = "A2"
        try container.save(a)

        let changes = try container.changes()
        #expect(changes.map(\.id) == [b.id, a.id])
        #expect(changes.map(\.version) == [1, 2])
        #expect(changes.allSatisfy { $0.kind == .save && $0.recordType == "Person" })
        #expect(try container.changeToken == changes.last?.token)
    }

    @Test func changesSinceATokenSkipEarlierOnes() throws {
        try container.save(Person(name: "Old"))
        let token = try container.changeToken
        let fresh = Person(name: "New")
        try container.save(fresh)
        #expect(try container.changes(since: token).map(\.id) == [fresh.id])
        #expect(try container.changes(since: container.changeToken).isEmpty)
    }

    @Test func deletesLeaveEntries() throws {
        let todo = ToDo(title: "Gone", subtasks: [Subtask(title: "Cascaded")])
        try container.save(todo)
        try container.delete(todo)

        let deletes = try container.changes().filter { $0.kind == .delete }
        #expect(Set(deletes.map(\.recordType)) == ["ToDo", "Subtask"])
        #expect(deletes.first { $0.id == todo.id }?.version == 2)
    }

    @Test func deletingATargetChangesItsOwners() throws {
        let note = Note(text: "Linked")
        let todo = ToDo(title: "Owner", notes: [note])
        try container.save(todo)
        try container.delete(note)
        #expect(try version(todo) == 2)
    }

    @Test func savingAgainAfterADeleteContinuesTheVersion() throws {
        let person = Person(name: "Back")
        try container.save(person)
        try container.delete(person)
        try container.save(person)
        #expect(try version(person) == 3)
        #expect(try container.changes().last?.kind == .save)
    }

    @Test func tagsAreStoredWithoutChangingTheVersion() throws {
        let person = Person(name: "Synced")
        try container.save(person)
        let token = try container.changeToken

        try container.setTag(Data([1, 2, 3]), for: Person.self, id: person.id)
        let metadata = try #require(try container.metadata(Person.self, id: person.id))
        #expect(metadata.tag == Data([1, 2, 3]))
        #expect(metadata.version == 1)
        #expect(try container.changes(since: token).isEmpty)

        // Records never see the bookkeeping, and saving a record keeps its tag.
        var fetched = try #require(try container.fetch(Person.self, id: person.id))
        fetched.name = "Edited"
        try container.save(fetched)
        #expect(try container.metadata(Person.self, id: person.id)?.tag == Data([1, 2, 3]))
    }

    @Test func missingRecordsHaveNoMetadata() throws {
        #expect(try container.metadata(Person.self, id: UUID()) == nil)
        try container.save(Person(name: "Someone"))
        #expect(try container.metadata(Person.self, id: UUID()) == nil)
    }

    @Test func rolledBackChangesLeaveNoEntries() throws {
        struct Abort: Error {}
        #expect(throws: Abort.self) {
            try container.transaction {
                try container.save(Person(name: "Never"))
                throw Abort()
            }
        }
        #expect(try container.changes().isEmpty)
    }
}

@MainActor
@Suite struct ContextChangeLogTests {
    let context = try! RecordContainer(zone: .inMemory).mainContext

    @Test func readingChangesSavesPendingEditsFirst() throws {
        let start = try context.changeToken
        let todo = ToDo(title: "Pending")
        context.save(todo)

        #expect(try context.changes(since: start).map(\.id) == [todo.id])
        #expect(!context.hasChanges)
        #expect(try context.metadata(ToDo.self, id: todo.id)?.version == 1)

        context.delete(todo)
        let deletes = try context.changes(since: start)
        #expect(deletes.map(\.kind) == [.delete])
        let later = ToDo(title: "Later")
        context.save(later)
        #expect(try context.changes(since: start).map(\.id) == [todo.id, later.id])
    }
}
