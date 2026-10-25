import Foundation
@testable import SwiftRecords
import Testing

@MainActor
@Suite struct RecordTrackerTests {
    let container = try! RecordContainer(for: [ToDo.self], inMemory: true)
    var context: RecordContext { container.mainContext }

    private func track(_ todo: ToDo) -> (RecordTracker<ToDo>, () -> ToDo) {
        let tracker = RecordTracker(todo)
        return (tracker, { [context] in tracker.update(context: context, initial: todo, zone: .default) {} })
    }

    @Test func showsTheStoredRecord() throws {
        context.autosaveEnabled = false
        var todo = ToDo(title: "Old")
        try container.save(todo)
        let (_, read) = track(todo)
        _ = read()
        todo.title = "New"
        context.insert(todo)
        try context.save()
        #expect(read().title == "New")
    }

    @Test func writesGoThroughTheContext() throws {
        context.autosaveEnabled = false
        let todo = ToDo(title: "Old")
        try container.save(todo)
        let (tracker, read) = track(todo)
        var edited = read()
        edited.title = "New"
        #expect(tracker.write(edited, context: context, zone: .default))
        #expect(!tracker.write(edited, context: context, zone: .default))
        #expect(tracker.hasChanges(in: context))
        #expect(read().title == "New")
        try context.save()
        #expect(!tracker.hasChanges(in: context))
        #expect(read().title == "New")
        #expect(try container.fetch(ToDo.self, id: todo.id)?.title == "New")
    }

    @Test func showsOtherCodesUnsavedEdits() throws {
        context.autosaveEnabled = false
        var todo = ToDo(title: "Old")
        try container.save(todo)
        let (_, read) = track(todo)
        _ = read()
        todo.title = "Unsaved"
        context.insert(todo)
        #expect(read().title == "Unsaved")
        context.rollback()
        #expect(read().title == "Old")
    }

    @Test func deleteKeepsTheLastValueAndIgnoresEdits() throws {
        context.autosaveEnabled = false
        let todo = ToDo(title: "Kept")
        try container.save(todo)
        let (tracker, read) = track(todo)
        _ = read()
        context.delete(todo)
        try context.save()
        #expect(read().title == "Kept")
        #expect(tracker.isDeleted)
        var edited = todo
        edited.title = "Revived"
        #expect(!tracker.write(edited, context: context, zone: .default))
        #expect(!context.hasChanges)
    }

    @Test func ownDeleteSaves() throws {
        context.autosaveEnabled = false
        let todo = ToDo(title: "Gone")
        try container.save(todo)
        let (tracker, read) = track(todo)
        _ = read()
        tracker.delete(context: context, zone: .default)
        #expect(tracker.isDeleted)
        try context.save()
        _ = read()
        #expect(tracker.isDeleted)
        #expect(try container.fetch(ToDo.self, id: todo.id) == nil)
    }

    @Test func unsavedInsertIsNotDeleted() {
        context.autosaveEnabled = false
        let todo = ToDo(title: "Draft")
        context.insert(todo)
        let (tracker, read) = track(todo)
        #expect(read().title == "Draft")
        #expect(!tracker.isDeleted)
    }
}
