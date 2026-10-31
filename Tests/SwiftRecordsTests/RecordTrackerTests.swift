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
        let todo = ToDo(title: "Draft")
        context.insert(todo)
        let (tracker, read) = track(todo)
        #expect(read().title == "Draft")
        #expect(!tracker.isDeleted)
    }
}

@MainActor
@Suite struct NewRecordTrackerTests {
    let container = try! RecordContainer(for: [ToDo.self], inMemory: true)
    var context: RecordContext { container.mainContext }

    @Test func newRecordIsInsertedByItsFirstEdit() throws {
        let draft = ToDo(title: "")
        let tracker = RecordTracker(draft)
        _ = tracker.update(context: context, initial: draft, zone: .default) {}
        #expect(tracker.isNew)
        #expect(!tracker.isDeleted)
        #expect(!context.hasChanges)
        var edited = draft
        edited.title = "Milk"
        #expect(tracker.write(edited, context: context, zone: .default))
        #expect(!tracker.isNew)
        try context.save()
        #expect(try container.fetch(ToDo.self, id: draft.id)?.title == "Milk")
    }

    @Test func aFreshDefaultDoesNotReplaceTheRecord() throws {
        let draft = ToDo(title: "")
        let tracker = RecordTracker(draft)
        _ = tracker.update(context: context, initial: draft, zone: .default) {}
        var edited = draft
        edited.title = "Milk"
        tracker.write(edited, context: context, zone: .default)
        // The view's default value is made again on the next render.
        #expect(tracker.update(context: context, initial: ToDo(title: ""), zone: .default) {}.title == "Milk")
        let stored = ToDo(title: "Stored")
        try container.save(stored)
        #expect(tracker.update(context: context, initial: stored, zone: .default) {}.title == "Stored")
    }

    @Test func startNewBeginsAnotherRecord() throws {
        let draft = ToDo(title: "")
        let tracker = RecordTracker(draft)
        _ = tracker.update(context: context, initial: draft, zone: .default) {}
        var edited = draft
        edited.title = "First"
        tracker.write(edited, context: context, zone: .default)
        let next = ToDo(title: "")
        tracker.startNew(next)
        #expect(tracker.update(context: context, initial: draft, zone: .default) {}.id == next.id)
        #expect(tracker.isNew)
        try context.save()
        #expect(try container.fetch(ToDo.self).map(\.title) == ["First"])
    }

    @Test func rollbackDropsOnlyUnsavedEdits() throws {
        let todo = ToDo(title: "Saved")
        try container.save(todo)
        let tracker = RecordTracker(todo)
        _ = tracker.update(context: context, initial: todo, zone: .default) {}
        var edited = todo
        edited.title = "Unsaved"
        tracker.write(edited, context: context, zone: .default)
        let other = ToDo(title: "Other")
        context.insert(other)
        tracker.rollback(context: context, zone: .default)
        #expect(tracker.update(context: context, initial: todo, zone: .default) {}.title == "Saved")
        #expect(context.unsavedChanges == 1)
        tracker.delete(context: context, zone: .default)
        tracker.rollback(context: context, zone: .default)
        #expect(!tracker.isDeleted)
        #expect(tracker.update(context: context, initial: todo, zone: .default) {}.title == "Saved")
    }

    @Test func rollbackReturnsAnUnsavedRecordToNew() throws {
        let draft = ToDo(title: "")
        let tracker = RecordTracker(draft)
        _ = tracker.update(context: context, initial: draft, zone: .default) {}
        var edited = draft
        edited.title = "Oops"
        tracker.write(edited, context: context, zone: .default)
        tracker.rollback(context: context, zone: .default)
        #expect(tracker.update(context: context, initial: draft, zone: .default) {}.title == "")
        #expect(tracker.isNew)
        #expect(!tracker.isDeleted)
        #expect(!context.hasChanges)
    }
}

/// A draft holds its edits until it commits, and still takes in changes from elsewhere.
@MainActor
@Suite struct DraftTrackerTests {
    let container = try! RecordContainer(for: [MergeContact.self], inMemory: true)
    var context: RecordContext { container.mainContext }

    private func track(_ contact: MergeContact) -> (RecordTracker<MergeContact>, () -> MergeContact) {
        let tracker = RecordTracker(contact, editing: .draft)
        return (tracker, { [context] in tracker.update(context: context, initial: contact, zone: .default) {} })
    }

    private func stored(_ id: UUID) throws -> MergeContact {
        try #require(try container.fetch(MergeContact.self, id: id))
    }

    /// Saves a change from elsewhere and lets the context hear of it.
    private func push(_ id: UUID, _ change: (inout MergeContact) -> Void) async throws {
        var other = try stored(id)
        change(&other)
        try container.save(other)
        for _ in 0..<20 { await Task.yield() }
    }

    private func commit() throws {
        try context.save()
    }

    @Test func editsStayInTheDraftUntilItCommits() throws {
        let contact = MergeContact()
        try container.save(contact)
        let (tracker, read) = track(contact)
        var edited = read()
        edited.name = "Bo"
        #expect(tracker.write(edited, context: context, zone: .default))
        #expect(read().name == "Bo")
        #expect(tracker.hasChanges(in: context))
        #expect(!context.hasChanges)
        #expect(try context.record(MergeContact.self, for: contact.id)?.name == "Ann")

        tracker.commit(context: context, zone: .default)
        try commit()
        #expect(try stored(contact.id).name == "Bo")
        #expect(!tracker.hasChanges(in: context))
    }

    @Test func rollingBackLeavesNothingBehind() throws {
        let contact = MergeContact()
        try container.save(contact)
        let (tracker, read) = track(contact)
        var edited = read()
        edited.name = "Bo"
        tracker.write(edited, context: context, zone: .default)
        tracker.rollback(context: context, zone: .default)
        #expect(read().name == "Ann")
        #expect(!tracker.hasChanges(in: context))
    }

    @Test func changesFromElsewhereMergeIntoTheDraft() async throws {
        let contact = MergeContact()
        try container.save(contact)
        let (tracker, read) = track(contact)
        var edited = read()
        edited.name = "Bo"
        edited.plays += 2
        tracker.write(edited, context: context, zone: .default)

        try await push(contact.id) {
            $0.place.city = "Bergen"
            $0.plays += 3
        }
        let current = read()
        #expect(current.name == "Bo")
        #expect(current.place.city == "Bergen")
        #expect(current.plays == 5)
        #expect(tracker.conflict(context: context, zone: .default) == nil)

        tracker.commit(context: context, zone: .default)
        try commit()
        #expect(try stored(contact.id).plays == 5)
        #expect(try stored(contact.id).place.city == "Bergen")
    }

    @Test func aClashInTheDraftIsAConflict() async throws {
        let contact = MergeContact()
        try container.save(contact)
        let (tracker, read) = track(contact)
        var edited = read()
        edited.name = "Bo"
        tracker.write(edited, context: context, zone: .default)

        try await push(contact.id) { $0.name = "Cy" }
        #expect(read().name == "Bo")
        #expect(tracker.conflict(context: context, zone: .default)?.name == "Cy")
        #expect(tracker.conflict(at: \.name, context: context, zone: .default))
        // The draft never reached the context.
        #expect(context.conflict(MergeContact.self, for: contact.id) == nil)

        tracker.resolve(favoring: .theirs, context: context, zone: .default)
        #expect(read().name == "Cy")
        #expect(tracker.conflict(context: context, zone: .default) == nil)
    }

    @Test func aNewRecordDraftSavesWhole() throws {
        let contact = MergeContact()
        let (tracker, read) = track(contact)
        var edited = read()
        edited.name = "Bo"
        tracker.write(edited, context: context, zone: .default)
        #expect(try container.fetch(MergeContact.self, id: contact.id) == nil)
        tracker.commit(context: context, zone: .default)
        try commit()
        #expect(try stored(contact.id).name == "Bo")
    }
}
