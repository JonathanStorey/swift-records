import Foundation
@testable import SwiftRecords
import Testing

/// An unsaved edit remembers the stored copy it started from, so saving it keeps what changed in the
/// store since then in the fields the edit left alone.
@MainActor
@Suite struct ChangedFieldSaveTests {
    let context = try! RecordContainer(inMemory: true).mainContext

    private func stored(_ todo: ToDo) throws -> ToDo? {
        try context.container.fetch(ToDo.self, id: todo.id)
    }

    @Test func aSaveKeepsFieldsChangedElsewhereSinceTheEditBegan() throws {
        var todo = ToDo(title: "Draft")
        context.insert(todo)
        try context.save()

        todo.title = "Edited"
        context.insert(todo)
        // Another writer, such as a sync, marks it done before the edit saves.
        var other = try #require(try stored(todo))
        other.done = true
        try context.container.save(other)

        try context.save()
        let saved = try #require(try stored(todo))
        #expect(saved.title == "Edited")
        #expect(saved.done)
    }

    @Test func theEditWinsAFieldBothChanged() throws {
        var todo = ToDo(title: "Draft", priority: 1)
        context.insert(todo)
        try context.save()

        todo.priority = 2
        context.insert(todo)
        var other = try #require(try stored(todo))
        other.priority = 3
        other.title = "Renamed"
        try context.container.save(other)

        try context.save()
        let saved = try #require(try stored(todo))
        #expect(saved.priority == 2)
        #expect(saved.title == "Renamed")
    }

    @Test func laterEditsKeepTheFirstEditsBase() throws {
        var todo = ToDo(title: "Draft")
        context.insert(todo)
        try context.save()

        todo.title = "Edited"
        context.insert(todo)
        var other = try #require(try stored(todo))
        other.done = true
        try context.container.save(other)
        // The view still shows its own copy, which never saw the other change.
        todo.priority = 5
        context.insert(todo)

        try context.save()
        let saved = try #require(try stored(todo))
        #expect(saved.title == "Edited")
        #expect(saved.priority == 5)
        #expect(saved.done)
    }

    @Test func aRecordDeletedSinceTheEditBeganStaysDeleted() throws {
        var todo = ToDo(title: "Draft")
        context.insert(todo)
        try context.save()

        todo.title = "Edited"
        context.insert(todo)
        try context.container.delete(todo)

        try context.save()
        #expect(try stored(todo) == nil)
    }

    @Test func aSaveWithNothingChangedElsewhereWritesTheEdit() throws {
        var todo = ToDo(title: "Draft", done: true)
        context.insert(todo)
        try context.save()

        todo.title = "Edited"
        todo.done = false
        context.insert(todo)
        try context.save()
        let saved = try #require(try stored(todo))
        #expect(saved.title == "Edited")
        #expect(!saved.done)
    }

    @Test func aNewRecordSavesWhole() throws {
        let todo = ToDo(title: "New", priority: 4)
        context.insert(todo)
        try context.save()
        #expect(try stored(todo)?.priority == 4)

        // Re-inserting a record after deleting it brings it back.
        context.delete(todo)
        try context.save()
        context.insert(todo)
        try context.save()
        #expect(try stored(todo)?.title == "New")
    }

    @Test func anAsyncSaveMergesToo() async throws {
        var todo = ToDo(title: "Draft")
        context.insert(todo)
        try await context.save()

        todo.title = "Edited"
        context.insert(todo)
        var other = try #require(try stored(todo))
        other.done = true
        try context.container.save(other)

        try await context.save()
        let saved = try #require(try stored(todo))
        #expect(saved.title == "Edited")
        #expect(saved.done)
    }
}
