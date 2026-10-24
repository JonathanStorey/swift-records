import Foundation
@testable import SwiftRecords
import Testing

@MainActor
@Suite struct RecordContextTests {
    let context = try! RecordContainer(inMemory: true).mainContext

    @Test func batchesChangesUntilSave() throws {
        context.autosaveEnabled = false
        context.insert(ToDo(title: "One"))
        context.insert(ToDo(title: "Two"))
        #expect(context.hasChanges)
        #expect(try context.container.fetch(ToDo.self).isEmpty)

        try context.save()
        #expect(!context.hasChanges)
        #expect(context.changeCount == 1)
        #expect(try context.container.fetch(ToDo.self).count == 2)
    }

    @Test func insertAddsAtTheEndOrReplacesInPlace() throws {
        context.autosaveEnabled = false
        var first = ToDo(title: "First")
        context.insert(first)
        context.insert(ToDo(title: "Second"))
        try context.save()

        first.title = "Edited"
        context.insert(first)
        #expect(try context.record(ToDo.self, for: first.id)?.title == "Edited")
        try context.save()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Edited", "Second"])

        // Once deleted, the record goes back in by its ID.
        context.delete(first)
        try context.save()
        context.insert(first)
        try context.save()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Edited", "Second"])
    }

    @Test func recordShowsUnsavedChangesWithoutSaving() throws {
        context.autosaveEnabled = false
        let todo = ToDo(title: "Draft")
        context.insert(todo)
        let found: ToDo? = try context.record(for: todo.id)
        #expect(found?.title == "Draft")
        #expect(context.unsavedChanges == 1)
        context.delete(todo)
        #expect(try context.record(ToDo.self, for: todo.id) == nil)
        #expect(context.unsavedChanges == 1)
    }

    @Test func descriptorsPageCountAndListIDs() throws {
        context.autosaveEnabled = false
        let todos = (0..<5).map { ToDo(title: "T\($0)", priority: $0) }
        context.apply(todos, replacing: [])
        let odd = #Predicate<ToDo> { $0.priority % 2 == 1 }
        #expect(try context.fetch(RecordDescriptor(predicate: odd)).map(\.title) == ["T1", "T3"])
        #expect(try context.fetch(RecordDescriptor<ToDo>(fetchLimit: 2, fetchOffset: 1)).map(\.title) == ["T1", "T2"])
        #expect(try context.fetchCount(RecordDescriptor<ToDo>()) == 5)
        #expect(try context.fetchCount(RecordDescriptor<ToDo>(fetchLimit: 2, fetchOffset: 4)) == 1)
        let high = #Predicate<ToDo> { $0.priority >= 3 }
        #expect(try context.fetchIdentifiers(RecordDescriptor(predicate: high)) == [todos[3].id, todos[4].id])
        #expect(try context.fetchIdentifiers(RecordDescriptor<ToDo>(fetchLimit: 1)) == [todos[0].id])
    }

    @Test func transactionSavesOrRollsBackItsOwnChanges() throws {
        context.autosaveEnabled = false
        context.insert(ToDo(title: "Earlier"))
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try context.transaction {
                context.insert(ToDo(title: "Dropped"))
                throw Stop()
            }
        }
        #expect(context.unsavedChanges == 1)

        try context.transaction {
            context.insert(ToDo(title: "Kept"))
        }
        #expect(!context.hasChanges)
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Earlier", "Kept"])
    }

    @Test func fetchIncludesPendingChanges() throws {
        context.autosaveEnabled = false
        context.insert(ToDo(title: "Pending"))
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Pending"])
    }

    @Test func autosavesOnNextTurn() async throws {
        context.autosaveDelay = .zero
        context.insert(ToDo(title: "Auto"))
        #expect(context.changeCount == 0)
        for _ in 0..<100 where context.changeCount == 0 {
            await Task.yield()
        }
        #expect(context.changeCount == 1)
        #expect(try context.container.fetch(ToDo.self).map(\.title) == ["Auto"])
    }

    @Test func applyInsertsUpdatesAndDeletes() throws {
        context.autosaveEnabled = false
        var todos = [ToDo(title: "A"), ToDo(title: "B"), ToDo(title: "C")]
        context.apply(todos, replacing: [])
        try context.save()

        let previous = todos
        todos.remove(at: 1)
        todos[0].title = "A2"
        todos.append(ToDo(title: "D"))
        todos.swapAt(0, 1)
        context.apply(todos, replacing: previous)
        try context.save()

        #expect(try context.container.fetch(ToDo.self).map(\.title) == ["A2", "C", "D"])
    }

    @Test func failedSaveRollsBackEverything() throws {
        context.autosaveEnabled = false
        let folder = Folder(name: "Kept", items: [Subtask(title: "Item")])
        try context.container.save(folder)

        context.insert(ToDo(title: "Should not land"))
        context.delete(folder)
        // Copying a file that does not exist fails the whole batch.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).jpg")
        var photo = Photo()
        photo.$image = Asset(contentsOf: missing)
        context.insert(photo)
        #expect(throws: (any Error).self) { try context.save() }
        #expect(try context.container.fetch(ToDo.self).isEmpty)
        #expect(try context.container.fetch(Folder.self, id: folder.id) != nil)
    }

    @Test func keepsOnlyTheLatestChangeToEachRecord() throws {
        context.autosaveEnabled = false
        var todo = ToDo(title: "T")
        let other = ToDo(title: "Other")
        context.insert(todo)
        context.insert(other)
        for title in ["Ty", "Typ", "Typed"] {
            todo.title = title
            context.insert(todo)
        }
        #expect(context.unsavedChanges == 2)
        try context.save()
        #expect(context.unsavedChanges == 0)
        #expect(try context.container.fetch(ToDo.self).map(\.title).sorted() == ["Other", "Typed"])

        context.insert(other)
        context.delete(other)
        try context.save()
        #expect(try context.container.fetch(ToDo.self).map(\.title) == ["Typed"])
    }

    @Test func autosaveWaitsForEditsToPause() async throws {
        context.autosaveDelay = .milliseconds(200)
        var todo = ToDo(title: "")
        for letter in "Hello" {
            todo.title.append(letter)
            context.insert(todo)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(context.changeCount == 0)
        #expect(context.hasChanges)

        for _ in 0..<100 where context.changeCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(context.changeCount == 1)
        #expect(try context.container.fetch(ToDo.self).map(\.title) == ["Hello"])
    }
}
