import Foundation
@testable import SwiftRecords
import Testing

@MainActor
@Suite struct AsyncContextTests {
    let context = try! RecordContainer(inMemory: true).mainContext

    init() {
        context.autosaveEnabled = false
    }

    /// In async code the compiler picks the async `save()`. A synchronous function reaches the other one.
    private func saveNow() throws {
        try context.save()
    }

    @Test func savesAndFetchesOffTheMainActor() async throws {
        context.insert(ToDo(title: "A", priority: 1))
        context.insert(ToDo(title: "B", priority: 2))
        try await context.save()
        #expect(!context.hasChanges)
        #expect(context.changeCount == 1)

        context.insert(ToDo(title: "C", priority: 3))
        let all: [ToDo] = try context.fetch(ToDo.self)
        #expect(all.map(\.title) == ["A", "B", "C"])
        let high: [ToDo] = try context.fetch(RecordDescriptor<ToDo>(predicate: #Predicate { $0.priority >= 2 }))
        #expect(high.map(\.title) == ["B", "C"])
        let page: [ToDo] = try context.fetch(RecordDescriptor<ToDo>(fetchLimit: 1, fetchOffset: 1))
        #expect(page.map(\.title) == ["B"])
        let count: Int = try context.fetchCount(RecordDescriptor<ToDo>())
        #expect(count == 3)
        let one: ToDo? = try context.record(ToDo.self, for: all[0].id)
        #expect(one?.title == "A")
        let ids = [all[2].id, all[0].id]
        let some: [UUID] = try context.fetchIdentifiers(RecordDescriptor<ToDo>(predicate: #Predicate { ids.contains($0.id) }))
        #expect(some == [all[0].id, all[2].id])
    }

    @Test func savesCommitInTheOrderTheyStarted() async throws {
        var todo = ToDo(title: "First")
        context.insert(todo)
        let first = Task { try await context.save() }
        todo.title = "Second"
        context.insert(todo)
        // The synchronous save waits for the async one, so the newer title wins.
        try saveNow()
        try await first.value
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Second"])
    }

    @Test func failedAsyncSaveKeepsChangesPending() async throws {
        context.insert(Measurement(value: .nan))
        await #expect(throws: RecordsError.self) { try await context.save() }
        #expect(context.unsavedChanges == 1)
    }

    @Test func autosaveCommitsOffTheMainActor() async throws {
        context.autosaveEnabled = true
        context.autosaveDelay = .zero
        context.insert(ToDo(title: "Auto"))
        for _ in 0..<1_000 where context.changeCount == 0 {
            await Task.yield()
        }
        #expect(context.changeCount == 1)
        #expect(try context.container.fetch(ToDo.self).map(\.title) == ["Auto"])
    }

    @Test func failedAutosaveDiscardsOnlyItsChanges() async throws {
        context.autosaveEnabled = true
        context.autosaveDelay = .zero
        context.insert(Measurement(value: .nan))
        for _ in 0..<1_000 where context.lastSaveError == nil {
            await Task.yield()
        }
        #expect(context.lastSaveError is RecordsError)
        #expect(!context.hasChanges)
    }
}

@MainActor
@Suite struct ExternalChangeTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    @Test func refreshPicksUpAnotherProcessesWrites() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try RecordContainer(directory: directory)
        let context = container.mainContext
        context.autosaveEnabled = false
        let person = Person(name: "Ana")
        context.insert(person)
        try await context.save()

        // A second connection stands in for an app extension.
        let other = try SQLiteDatabase(url: try #require(container.url))
        _ = try other.run("UPDATE \"Person\" SET name = 'Bea'")
        try other.execute("CREATE TABLE \"Extra\" (\"id\" PRIMARY KEY)")

        let before = context.changeCount
        try await context.refresh()
        for _ in 0..<100 where context.changeCount == before {
            await Task.yield()
        }
        #expect(context.changeCount > before)
        #expect(try context.fetch(Person.self).map(\.name) == ["Bea"])

        // Nothing new, nothing to refresh.
        let after = context.changeCount
        try await context.refresh()
        for _ in 0..<20 { await Task.yield() }
        #expect(context.changeCount == after)
    }
}
