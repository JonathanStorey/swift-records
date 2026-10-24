import Foundation
@testable import SwiftRecords
import Testing

@MainActor
@Suite struct ResilienceTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    @Test func autosaveKeepsChangesWhileAnotherProcessHoldsTheFile() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try RecordContainer(directory: directory)
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(Person(name: "Ana"))
        try await context.save()
        container.defaultStorage.store.db.setBusyTimeout(0)

        // A second connection stands in for a widget in the middle of a write.
        let other = try SQLiteDatabase(url: try #require(container.url))
        try other.execute("BEGIN IMMEDIATE")
        context.autosaveEnabled = true
        context.autosaveDelay = .zero
        context.insert(Person(name: "Bea"))
        for _ in 0..<1_000 where context.lastSaveError == nil {
            await Task.yield()
        }
        #expect(context.lastSaveError is RecordsError)
        #expect(context.unsavedChanges == 1)

        // Once the other write ends, the retry a second later saves the change.
        try other.execute("COMMIT")
        for _ in 0..<100 where context.unsavedChanges > 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(context.lastSaveError == nil)
        #expect(try container.fetch(Person.self).map(\.name) == ["Ana", "Bea"])
    }

    @Test func writesHoldTheLockFromTheStart() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try RecordContainer(directory: directory)
        try container.save(Person(name: "Ana"))
        let store = container.defaultStorage.store
        let other = try SQLiteDatabase(url: try #require(container.url))
        other.setBusyTimeout(0)

        // Reading first doesn't leave room for another process to commit before this transaction writes.
        try store.transaction {
            _ = try store.db.run("SELECT * FROM \"Person\"")
            #expect(throws: (any Error).self) { try other.run("UPDATE \"Person\" SET name = 'Bea'") }
            try store.db.run("UPDATE \"Person\" SET name = 'Cy'")
        }
        #expect(try container.fetch(Person.self).map(\.name) == ["Cy"])
    }

    @Test func storedOrderIsIndexed() throws {
        let container = try RecordContainer(inMemory: true)
        try container.save(Person(name: "Ana"))
        let indexes = try container.defaultStorage.store.db.run(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'Person'"
        )
        #expect(indexes.contains { $0["name"] == .text("Person._position") })
    }

    @Test func recordShowsAChangeWhileItsSaveCommits() async throws {
        let context = try RecordContainer(inMemory: true).mainContext
        context.autosaveEnabled = false
        var todo = ToDo(title: "Old")
        context.insert(todo)
        try await context.save()

        // Another thread holds the store, so the next save waits in flight.
        let store = context.container.defaultStorage.store
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? store.transaction {
                held.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        held.wait()
        todo.title = "New"
        context.insert(todo)
        let save = Task { try await context.save() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!context.hasChanges)
        #expect(try context.record(ToDo.self, for: todo.id)?.title == "New")
        release.signal()
        try await save.value
    }
}
