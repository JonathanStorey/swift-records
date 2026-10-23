import Foundation
@testable import SwiftRecords
import Testing

/// Checks that edits which only change values skip structural work, so views can keep their caches.
@MainActor
@Suite struct ChangeTrackingTests {
    let context = try! RecordContainer(inMemory: true).mainContext

    @Test func editingANestedValueIsNotStructural() throws {
        context.autosaveEnabled = false
        let source = ObjectIdentifier(NSObject())
        var todos = [ToDo(title: "A", notes: [Note(text: "h")]), ToDo(title: "B")]
        context.apply(todos, replacing: [], source: source)
        try context.save()
        #expect(context.lastSaveSource == nil)  // links were created

        let structure = context.container.structureVersion
        let previous = todos
        todos[0].notes[0].text = "hello"
        context.apply(todos, replacing: previous, source: source)
        try context.save()
        #expect(context.container.structureVersion == structure)
        #expect(context.lastSaveSource == source)
        #expect(try context.container.fetch(Note.self).map(\.text) == ["hello"])
    }

    @Test func reorderingOrDeletingIsStructuralOnlyWhenLinksChange() throws {
        context.autosaveEnabled = false
        let source = ObjectIdentifier(NSObject())
        var todos = [ToDo(title: "A"), ToDo(title: "B")]
        context.apply(todos, replacing: [], source: source)
        try context.save()

        // Moving rows only rewrites positions, which the cache already shows.
        var previous = todos
        todos.swapAt(0, 1)
        context.apply(todos, replacing: previous, source: source)
        try context.save()
        #expect(context.lastSaveSource == source)
        #expect(try context.container.fetch(ToDo.self).map(\.title) == ["B", "A"])

        previous = todos
        todos.removeLast()
        context.apply(todos, replacing: previous, source: source)
        try context.save()
        #expect(context.lastSaveSource == nil)
    }

    @Test func changesFromSeveralSourcesAreNotAttributed() throws {
        context.autosaveEnabled = false
        let todo = ToDo(title: "A")
        context.apply([todo], replacing: [], source: ObjectIdentifier(NSObject()))
        context.insert(ToDo(title: "B"))
        try context.save()
        #expect(context.lastSaveSource == nil)
    }
}
