import Foundation
@testable import SwiftRecords
import Testing

@MainActor
@Suite struct UndoTests {
    let container = try! RecordContainer(inMemory: true)
    var context: RecordContext { container.mainContext }
    /// What undoes each save, newest last, as an undo manager's stack would hold it.
    let steps = Steps()

    final class Steps {
        var all: [RecordContext.SaveStep] = []
    }

    init() {
        let steps = steps
        container.mainContext.registerUndo = { steps.all.append($0) }
    }

    /// Undoes the newest step, which registers the step that redoes it.
    private func undoLast() throws {
        try context.undo(steps.all.removeLast())
    }

    @Test func eachSaveIsOneStep() throws {
        var todo = ToDo(title: "Draft")
        context.insert(todo)
        context.insert(ToDo(title: "Other"))
        try context.save()
        todo.title = "First"
        context.insert(todo)
        todo.title = "Second"
        context.insert(todo)
        try context.save()
        #expect(steps.all.count == 2)
        let (first, second) = (steps.all[0], steps.all[1])

        try context.undo(second)
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Draft", "Other"])
        try context.undo(first)
        #expect(try context.fetch(ToDo.self).isEmpty)
        // A save that changes nothing isn't a step.
        let count = steps.all.count
        try context.save()
        #expect(steps.all.count == count)
    }

    @Test func redoPutsTheSaveBack() throws {
        var todo = ToDo(title: "Draft")
        context.insert(todo)
        try context.save()
        todo.title = "Edited"
        context.insert(todo)
        try context.save()

        try undoLast()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Draft"])
        // Undoing registered the redo, which in turn registers the undo again.
        try undoLast()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Edited"])
        try undoLast()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Draft"])
    }

    @Test func undoingADeleteBringsBackItsCascade() throws {
        let album = Album(photos: [Photo(caption: "A"), Photo(caption: "B"), Photo(caption: "C")])
        context.insert(album)
        try context.save()
        context.delete(album)
        try context.save()
        #expect(try container.fetch(Photo.self).isEmpty)

        try undoLast()
        let restored = try #require(try container.fetch(Album.self, id: album.id))
        #expect(restored.photos.map(\.caption) == ["A", "B", "C"])
        #expect(try container.fetch(Photo.self).allSatisfy { $0.album == album.id })

        try undoLast()
        #expect(try container.fetch(Album.self).isEmpty)
        #expect(try container.fetch(Photo.self).isEmpty)
    }

    @Test func undoingAMoveRestoresOrderAndParents() throws {
        var first = Album(photos: [Photo(caption: "A"), Photo(caption: "B")])
        var second = Album()
        context.insert(first)
        context.insert(second)
        try context.save()

        second.photos = [first.photos.removeFirst()]
        first.photos.append(Photo(caption: "C"))
        context.insert(first)
        context.insert(second)
        try context.save()

        try undoLast()
        #expect(try container.fetch(Album.self, id: first.id)?.photos.map(\.caption) == ["A", "B"])
        #expect(try container.fetch(Album.self, id: second.id)?.photos.isEmpty == true)
        #expect(try container.fetch(Photo.self).map(\.caption).sorted() == ["A", "B"])
    }

    @Test func undoingADeleteBringsBackItsAssetFile() throws {
        let photo = Photo(caption: "Sunset", image: Data("pixels".utf8))
        context.insert(photo)
        try context.save()
        context.delete(photo)
        try context.save()
        #expect(try container.fetch(Photo.self).isEmpty)

        try undoLast()
        let restored = try #require(try container.fetch(Photo.self, id: photo.id))
        #expect(restored.image == Data("pixels".utf8))
    }

    @Test func undoIsLoggedAsAChange() throws {
        let todo = ToDo(title: "Draft")
        context.insert(todo)
        try context.save()
        let token = try container.initialStorage.changeToken

        try undoLast()
        let changes = try container.initialStorage.changes(since: token)
        #expect(changes.map(\.kind) == [.delete])
        #expect(changes.map(\.id) == [todo.id])
    }

    @Test func unsavedChangesStayPending() throws {
        var todo = ToDo(title: "Saved")
        context.insert(todo)
        try context.save()
        todo.title = "Typing"
        context.insert(todo)

        try undoLast()
        #expect(try context.container.fetch(ToDo.self).isEmpty)
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Typing"])
        #expect(context.hasChanges)
    }

    @Test func savesSkipTheJournalWithoutUndo() throws {
        context.registerUndo = nil
        context.insert(ToDo(title: "Draft"))
        try context.save()
        #expect(steps.all.isEmpty)
        #expect(container.initialStorage.store.journal == nil)
    }

    @Test func viewsHearTheUndo() throws {
        context.insert(ToDo(title: "Draft"))
        try context.save()
        let before = context.changeCount
        try undoLast()
        #expect(context.changeCount > before)
        #expect(context.lastSaveSource == nil)
    }
}

#if canImport(Darwin)
@MainActor
@Suite struct UndoManagerTests {
    @Test func undoAndRedoEachSave() throws {
        let context = try RecordContainer(inMemory: true).mainContext
        let manager = UndoManager()
        manager.groupsByEvent = false
        context.undoManager = manager

        var todo = ToDo(title: "Draft")
        context.insert(todo)
        try context.save()
        todo.title = "Edited"
        context.insert(todo)
        try context.save()

        manager.undo()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Draft"])
        manager.undo()
        #expect(try context.fetch(ToDo.self).isEmpty)
        #expect(!manager.canUndo)
        manager.redo()
        manager.redo()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Edited"])
        #expect(!manager.canRedo)
    }
}
#endif
