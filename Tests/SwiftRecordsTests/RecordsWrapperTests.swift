#if canImport(SwiftUI)
import Foundation
import SwiftUI
@testable import SwiftRecords
import Testing

/// Each form of `@Records` compiles against the property type it fills.
@MainActor
private struct WrapperUses: View {
    @Records var todos: [ToDo]
    @Records(filter: #Predicate<ToDo> { $0.done }) var done: [ToDo]
    @Records(ids: []) var some: [ToDo]
    @Records(.default, ids: []) var other: [Note]
    @Records("pantry") var pantry: [Person]
    @Records(RecordDescriptor<ToDo>(predicate: #Predicate { !$0.done }, fetchLimit: 20)) var firstOpen: [ToDo]
    @Records("pantry", RecordDescriptor<Person>(fetchLimit: 5)) var someone: [Person]
    @Records(sort: \ToDo.title) var byTitle: [ToDo]
    @Records(sort: \ToDo.due, order: .reverse, animation: nil) var byDue: [ToDo]
    @Records(filter: #Predicate<ToDo> { !$0.done }, sort: [SortDescriptor(\ToDo.priority, order: .reverse)]) var urgent: [ToDo]
    @Records("pantry", sort: [SortDescriptor(\Person.name)]) var people: [Person]

    /// `$todos` edits and pages like an array's binding.
    var body: some View {
        List($firstOpen, editActions: .delete) { $todo in
            TextField("Title", text: $todo.title)
        }
        .refreshable { try? await $firstOpen.refresh() }
        .toolbar {
            Button("Next") { $firstOpen.nextPage() }.disabled(!$firstOpen.hasNextPage)
            Button("More") { $firstOpen.loadMore() }
            Button("First") { $firstOpen.page = 0 }
            Text("\($firstOpen.totalCount) in \($firstOpen.pageCount) pages")
            ForEach($todos) { $todo in Toggle(todo.title, isOn: $todo.done) }
        }
    }
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
        let query = Records<ToDo>.Query.list(ids: [first.id, second.id])
        #expect(try query.fetch(container.initialStorage, query.page).map(\.title) == ["First", "Second"])
    }

    @Test func environmentContextIsTheContainersMainContext() {
        var environment = EnvironmentValues()
        environment.recordContainer = container
        #expect(environment.recordContext === container.mainContext)
    }

    @Test func unsavedAppendsShowInEveryForm() throws {
        let context = container.mainContext
        context.autosaveEnabled = false
        let todo = ToDo(title: "New", done: true)
        context.insert(todo)

        let all = Records<ToDo>.Query.list(RecordDescriptor())
        #expect(all.overlay(context, .default, try all.fetch(container.initialStorage, all.page), all.page).map(\.title) == ["New"])
        let done = Records<ToDo>.Query.list(RecordDescriptor(predicate: #Predicate<ToDo> { $0.done }))
        #expect(done.overlay(context, .default, try done.fetch(container.initialStorage, done.page), done.page).map(\.title) == ["New"])
        let ids = Records<ToDo>.Query.list(ids: [todo.id])
        #expect(ids.overlay(context, .default, try ids.fetch(container.initialStorage, ids.page), ids.page).map(\.title) == ["New"])
    }
}
#endif
