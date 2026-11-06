import Foundation
@testable import SwiftRecords
import Testing

/// Checks that edits which only change values skip structural work, so views can keep their caches.
@MainActor
@Suite struct ChangeTrackingTests {
    let context = try! RecordContainer(inMemory: true).mainContext

    @Test func editingANestedValueIsNotStructural() throws {
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

    @Test func editingIsStructuralOnlyWhenLinksChange() throws {
        let source = ObjectIdentifier(NSObject())
        var todos = [ToDo(title: "A"), ToDo(title: "B")]
        context.apply(todos, replacing: [], source: source)
        try context.save()

        // Editing a title only rewrites the row, which the cache already shows.
        var previous = todos
        todos[0].title = "A2"
        context.apply(todos, replacing: previous, source: source)
        try context.save()
        #expect(context.lastSaveSource == source)

        previous = todos
        todos.removeLast()
        context.apply(todos, replacing: previous, source: source)
        try context.save()
        #expect(context.lastSaveSource == nil)
    }

    @Test func changesFromSeveralSourcesAreNotAttributed() throws {
        let todo = ToDo(title: "A")
        context.apply([todo], replacing: [], source: ObjectIdentifier(NSObject()))
        context.insert(ToDo(title: "B"))
        try context.save()
        #expect(context.lastSaveSource == nil)
    }
}
