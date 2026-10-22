#if canImport(SwiftUI)
import Foundation
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
}

@MainActor
@Suite struct RecordsWrapperTests {
    let container = try! RecordContainer(for: [ToDo.self], zone: .inMemory)

    @Test func idsLoadInStoredOrder() throws {
        let first = ToDo(title: "First")
        let second = ToDo(title: "Second")
        try container.save([second, first, ToDo(title: "Other")])
        let query = Records<[ToDo]>.Query.list(ids: [first.id, second.id])
        #expect(try query.fetch(container).map(\.title) == ["Second", "First"])
    }

    @Test func singleRecordReadsSavesAndDeletes() throws {
        let context = container.mainContext
        var todo = ToDo(title: "One")
        try container.save(todo)
        let query = Records<ToDo?>.Query.single(id: todo.id)
        #expect(try query.fetch(container)?.title == "One")

        todo.title = "Edited"
        query.write(context, todo, nil, ObjectIdentifier(container))
        try context.save()
        #expect(try query.fetch(container)?.title == "Edited")

        query.write(context, nil, todo, ObjectIdentifier(container))
        try context.save()
        #expect(try query.fetch(container) == nil)
    }
}
#endif
