import Foundation
import SwiftRecords
import Testing

@MainActor
@Suite struct RecordsContextTests {
    let context = try! RecordsContext(zone: .inMemory)

    @Test func batchesChangesUntilSave() throws {
        context.autosaveEnabled = false
        context.save(ToDo(title: "One"))
        context.save(ToDo(title: "Two"))
        #expect(context.hasChanges)
        #expect(try context.container.fetch(ToDo.self).isEmpty)

        try context.save()
        #expect(!context.hasChanges)
        #expect(context.changeCount == 1)
        #expect(try context.container.fetch(ToDo.self).count == 2)
    }

    @Test func fetchIncludesPendingChanges() throws {
        context.autosaveEnabled = false
        context.save(ToDo(title: "Pending"))
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Pending"])
    }

    @Test func autosavesOnNextTurn() async throws {
        context.save(ToDo(title: "Auto"))
        #expect(context.changeCount == 0)
        for _ in 0..<100 where context.changeCount == 0 {
            await Task.yield()
        }
        #expect(context.changeCount == 1)
        #expect(try context.container.fetch(ToDo.self).map(\.title) == ["Auto"])
    }

    @Test func applyInsertsUpdatesDeletesAndOrders() throws {
        context.autosaveEnabled = false
        var todos = [ToDo(title: "A"), ToDo(title: "B"), ToDo(title: "C")]
        context.apply(todos, replacing: [], keepOrder: true)
        try context.save()

        let previous = todos
        todos.remove(at: 1)
        todos[0].title = "A2"
        todos.append(ToDo(title: "D"))
        todos.swapAt(0, 1)
        context.apply(todos, replacing: previous, keepOrder: true)
        try context.save()

        #expect(try context.container.fetch(ToDo.self).map(\.title) == ["C", "A2", "D"])
    }

    @Test func failedSaveRollsBackEverything() throws {
        context.autosaveEnabled = false
        let folder = Folder(id: 7, name: "Locked", items: [Subtask(title: "Item")])
        try context.container.save(folder)

        context.save(ToDo(title: "Should not land"))
        context.delete(folder)
        #expect(throws: RecordContainerError.self) { try context.save() }
        #expect(try context.container.fetch(ToDo.self).isEmpty)
        #expect(try context.container.fetch(Folder.self, id: 7) != nil)
    }
}
