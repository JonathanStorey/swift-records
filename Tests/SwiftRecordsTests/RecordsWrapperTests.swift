#if canImport(SwiftUI)
import Foundation
import SwiftUI
@testable import SwiftRecords
import Testing

/// Each form of `@Records` compiles against the property type it fills.
@MainActor
private struct WrapperUses {
    @Records var todos: [ToDo]
    @Records(filter: #Predicate<ToDo> { $0.done }) var done: [ToDo]
    @Records(ids: []) var some: [ToDo]
    @Records(id: UUID()) var one: ToDo?
    @Records(.default, id: UUID()) var other: Note?
    @Records("pantry") var pantry: [Person]
    @Records(RecordDescriptor<ToDo>(predicate: #Predicate { !$0.done }, fetchLimit: 20)) var firstOpen: [ToDo]
    @Records("pantry", RecordDescriptor<Person>(fetchLimit: 5)) var someone: [Person]
    @Records(sort: \ToDo.title) var byTitle: [ToDo]
    @Records(sort: \ToDo.due, order: .reverse) var byDue: [ToDo]
    @Records(filter: #Predicate<ToDo> { !$0.done }, sort: [SortDescriptor(\ToDo.priority, order: .reverse)]) var urgent: [ToDo]
    @Records("pantry", sort: [SortDescriptor(\Person.name)]) var people: [Person]
}

/// A bare `@Records` stays out of the memberwise initializer, as `@Query` does.
@MainActor
private struct RecipeList {
    @Records var todos: [ToDo]
    var title = "All"
}

@MainActor
private func makeLists() -> [RecipeList] {
    [RecipeList(), RecipeList(title: "Mine")]
}

@MainActor
@Suite struct RecordsWrapperTests {
    let container = try! RecordContainer(for: [ToDo.self], inMemory: true)

    @Test func idsLoadSortedByID() throws {
        let first = ToDo(title: "First")
        let second = ToDo(title: "Second")
        try container.save([second, first, ToDo(title: "Other")])
        let query = Records<[ToDo]>.Query.list(ids: [first.id, second.id])
        #expect(try query.fetch(container.defaultStorage).map(\.title) == ["First", "Second"])
    }

    @Test func environmentContextIsTheContainersMainContext() {
        var environment = EnvironmentValues()
        environment.recordContainer = container
        #expect(environment.recordContext === container.mainContext)
    }

    @Test func singleRecordReadsSavesAndDeletes() throws {
        let context = container.mainContext
        var todo = ToDo(title: "One")
        try container.save(todo)
        let query = Records<ToDo?>.Query.single(id: todo.id)
        #expect(try query.fetch(container.defaultStorage)?.title == "One")

        todo.title = "Edited"
        _ = query.write(context, .default, todo, nil, ObjectIdentifier(container))
        try context.save()
        #expect(try query.fetch(container.defaultStorage)?.title == "Edited")

        _ = query.write(context, .default, nil, todo, ObjectIdentifier(container))
        try context.save()
        #expect(try query.fetch(container.defaultStorage) == nil)
    }

    @Test func sortedListsKeepTheirOrderThroughEdits() throws {
        let context = container.mainContext
        context.autosaveEnabled = false
        try container.save([ToDo(title: "Low", priority: 1), ToDo(title: "High", priority: 9)])
        let query = Records<[ToDo]>.Query.list(RecordDescriptor(sortBy: [SortDescriptor(\ToDo.priority, order: .reverse)]))
        let stored = try query.fetch(container.defaultStorage)
        #expect(stored.map(\.title) == ["High", "Low"])

        // Raising a priority through the binding moves the row up, and a new row lands in its place.
        var edited = stored
        edited[1].priority = 10
        edited.append(ToDo(title: "Middle", priority: 5))
        let shown = query.write(context, .default, edited, stored, ObjectIdentifier(container))
        #expect(shown.map(\.title) == ["Low", "High", "Middle"])
        #expect(query.overlay(context, .default, stored).map(\.title) == ["Low", "High", "Middle"])

        let other = Records<[ToDo]>.Query.list(RecordDescriptor(sortBy: [SortDescriptor(\ToDo.priority)]))
        #expect(query.key != other.key)
    }

    @Test func descriptorPagesHoldAtMostTheirLimit() throws {
        let context = container.mainContext
        context.autosaveEnabled = false
        try container.save((0..<4).map { ToDo(title: "T\($0)") })

        let page = Records<[ToDo]>.Query.list(RecordDescriptor(fetchLimit: 2, fetchOffset: 1))
        let stored = try page.fetch(container.defaultStorage)
        #expect(stored.map(\.title) == ["T1", "T2"])
        context.insert(ToDo(title: "New"))
        #expect(page.overlay(context, .default, stored).map(\.title) == ["T1", "T2"])
        let first = Records<[ToDo]>.Query.list(RecordDescriptor(fetchLimit: 10))
        #expect(first.overlay(context, .default, try first.fetch(container.defaultStorage)).count == 5)
        #expect(page.key != first.key)
    }

    @Test func aChangedFilterFetchesAgain() {
        func search(_ text: String) -> Records<[ToDo]>.Query {
            .list(RecordDescriptor(predicate: #Predicate<ToDo> { $0.title == text }))
        }
        // A view's body builds its query again each time, so only a different filter changes the key.
        #expect(search("Milk").key == search("Milk").key)
        #expect(search("Milk").key != search("Eggs").key)
    }

    @Test func unsavedAppendsShowInEveryForm() throws {
        let context = container.mainContext
        context.autosaveEnabled = false
        let todo = ToDo(title: "New", done: true)
        context.insert(todo)

        let all = Records<[ToDo]>.Query.list(RecordDescriptor())
        #expect(all.overlay(context, .default, try all.fetch(container.defaultStorage)).map(\.title) == ["New"])
        let done = Records<[ToDo]>.Query.list(RecordDescriptor(predicate: #Predicate<ToDo> { $0.done }))
        #expect(done.overlay(context, .default, try done.fetch(container.defaultStorage)).map(\.title) == ["New"])
        let ids = Records<[ToDo]>.Query.list(ids: [todo.id])
        #expect(ids.overlay(context, .default, try ids.fetch(container.defaultStorage)).map(\.title) == ["New"])
        let one = Records<ToDo?>.Query.single(id: todo.id)
        #expect(one.overlay(context, .default, try one.fetch(container.defaultStorage))?.title == "New")
        let bare = [ToDo].allRecordsQuery()
        #expect(bare.overlay(context, .default, try bare.fetch(container.defaultStorage)).map(\.title) == ["New"])
    }
}
#endif
