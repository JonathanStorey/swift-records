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
        for _ in 0..<100 where context.unsavedChanges > 0 || context.lastSaveError != nil {
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

    @Test func referencesAreIndexed() throws {
        let container = try RecordContainer(for: [SyncRecipe.self], inMemory: true)
        try container.save(SyncRecipe(title: "Soup", steps: [SyncStep(text: "Chop")]))
        let indexes = try container.defaultStorage.store.db.run(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'SyncStep'"
        )
        #expect(indexes.contains { $0["name"] == .text("SyncStep.recipe.index") })
    }

    @Test func pendingChangesReadOnlyUnsentRows() throws {
        let container = try RecordContainer(inMemory: true)
        try container.save(Person(name: "Ana"))
        let db = container.defaultStorage.store.db
        for query in [
            "SELECT record_table FROM \"_records_meta\" WHERE kind IS NOT NULL AND version > acked ORDER BY seq",
            "SELECT COUNT(*) FROM \"_records_meta\" WHERE kind IS NOT NULL AND version > acked",
        ] {
            let plan = try db.run("EXPLAIN QUERY PLAN " + query).compactMap { row -> String? in
                if case .text(let detail)? = row["detail"] { return detail }
                return nil
            }
            #expect(plan.contains { $0.contains("_records_meta.pending") }, "\(plan)")
        }
        #expect(try container.defaultStorage.store.pendingChangeCount() == 1)
    }

    @Test func bookkeepingFitsInFewTables() throws {
        let container = try RecordContainer(inMemory: true)
        try container.save(Person(name: "Ana"))
        let tables = try container.defaultStorage.store.db.run(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '\\_records\\_%' ESCAPE '\\'"
        ).compactMap { row -> String? in
            if case .text(let name)? = row["name"] { return name }
            return nil
        }
        #expect(Set(tables) == ["_records_assets", "_records_meta", "_records_relations", "_records_sync_state"])
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
        block(until: held)
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

@MainActor
@Suite struct PartialFailureTests {
    let container = try! RecordContainer(inMemory: true)

    @Test func aRecordThatDoesNotDecodeIsSkippedAndReported() async throws {
        let context = container.mainContext
        context.autosaveEnabled = false
        let bad = ToDo(title: "Bad")
        try container.save([ToDo(title: "A"), bad, ToDo(title: "B")])
        // As if a property changed type: the stored value no longer decodes.
        try container.defaultStorage.store.db.run(
            "UPDATE \"ToDo\" SET priority = 'high' WHERE id = ?", [try ValueCoding.encode(bad.id)]
        )

        #expect(try context.fetch(ToDo.self).map(\.title) == ["A", "B"])
        for _ in 0..<20 { await Task.yield() }
        #expect(context.status == .failed(.incompatibleRecord(type: "ToDo", id: bad.id)))

        context.delete(bad)
        try await context.save()
        for _ in 0..<20 { await Task.yield() }
        #expect(context.status == .saved)
    }

    @Test func translatableTermsRunInSQLAndTheRestInMemory() throws {
        try container.save((0..<6).map { ToDo(title: String(repeating: "x", count: $0 + 1), priority: $0) })
        let mixed = #Predicate<ToDo> { $0.priority >= 2 && $0.title.count != 4 }
        let clause = try #require(PredicateTranslator.translateTerms(mixed))
        #expect(clause.sql.contains("priority"))
        #expect(!clause.sql.contains("title"))

        let records: [ToDo] = try container.fetch(ToDo.self, where: mixed)
        #expect(records.map(\.priority) == [2, 4, 5])
        let page = try container.defaultStorage.fetch(RecordDescriptor(predicate: mixed, fetchLimit: 2, fetchOffset: 1))
        #expect(page.map(\.priority) == [4, 5])
        #expect(try container.defaultStorage.fetchCount(RecordDescriptor(predicate: mixed)) == 3)
    }

    @Test func aBindingWriteSavesOnlyWhatChanged() throws {
        let context = container.mainContext
        context.autosaveEnabled = false
        let todos = (0..<5).map { ToDo(title: "T\($0)") }
        try container.save(todos)
        var edited = todos
        edited[2].title = "Changed"
        context.apply(edited, replacing: todos)
        #expect(context.unsavedChanges == 1)

        context.rollback()
        // The order isn't stored, so a move saves nothing and the view shows the records by ID again.
        #expect(context.apply(Array(todos.reversed()), replacing: todos).map(\.id) == todos.map(\.id))
        #expect(!context.hasChanges)
    }
}

/// Waits on a semaphore from a test, which can't call `wait()` in an async context directly.
private func block(until semaphore: DispatchSemaphore) {
    semaphore.wait()
}
