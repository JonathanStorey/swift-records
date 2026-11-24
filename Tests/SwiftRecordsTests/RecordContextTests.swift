import Foundation
import Testing
@testable import SwiftRecords
import Versioning

@Suite struct RecordContextTests {
    @MainActor @Test func theMainContextIsMadeOnceAndKept() {
        let container = RecordContainer()
        #expect(container.mainContext === container.mainContext)
    }

    @MainActor @Test func theMainContextBelongsToItsContainer() {
        let container = RecordContainer()
        #expect(container.mainContext.container === container)
    }

    @MainActor @Test func eachContainerHasItsOwnMainContext() {
        #expect(RecordContainer().mainContext !== RecordContainer().mainContext)
    }

    @Test func anotherContextIsSeparateFromTheMainOne() async {
        let container = RecordContainer()
        let context = RecordContext(container)
        let main = await MainActor.run { ObjectIdentifier(container.mainContext) }
        #expect(ObjectIdentifier(context) != main)
        #expect(context.container === container)
    }
}

private struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var body = ""
}

private struct Page: Codable, Identifiable, Equatable {
    var id: String
    var title = ""
}

/// `insert(_:)` opens a draft and writes nothing.
@Suite struct RecordContextInsertTests {
    private let container = RecordContainer.inMemory(Note.self, Page.self)

    private func draft<R: Codable & Identifiable>(_ record: R, in context: RecordContext, zone: Zone = "Records") throws -> Draft<R>? where R.ID: Encodable {
        let name = try RecordContainer.recordName(for: record.id, type: RecordContainer.recordType(of: R.self))
        return context.drafts[RecordContainer.RowID(name: name, zone: zone)] as? Draft<R>
    }

    @Test func aNewRecordOpensADraftWithNoBase() throws {
        let context = RecordContext(container)
        let note = Note(title: "Groceries")
        context.insert(note)

        let draft = try #require(try draft(note, in: context))
        #expect(draft.ours == note)
        #expect(draft.base == nil)
        #expect(try container.row(id: note.id) == nil, "Nothing is written before a save.")
    }

    @Test func aSavedRecordTakesItsSavedValueAsTheBase() throws {
        let saved = Note(title: "Saved")
        try container.save(our: saved, zone: "Records")
        let context = RecordContext(container)
        context.insert(Note(id: saved.id, title: "Edited"))

        let draft = try #require(try draft(saved, in: context))
        #expect(draft.base == saved)
        #expect(draft.ours.title == "Edited")
    }

    @Test func insertingAgainKeepsTheDraftAndReplacesTheEdit() throws {
        let context = RecordContext(container)
        let note = Note(title: "First")
        context.insert(note)
        let first = try #require(try draft(note, in: context))
        context.insert(Note(id: note.id, title: "Second"))

        let second = try #require(try draft(note, in: context))
        #expect(first === second, "A view watching the draft keeps watching it.")
        #expect(second.ours.title == "Second")
        #expect(second.base == nil)
    }

    @Test func theZoneDecidesTheRow() throws {
        let note = Note(title: "Saved")
        try container.save(our: note, zone: "Records")
        let context = RecordContext(container)
        context.zone = "Elsewhere"
        context.insert(Note(id: note.id, title: "Edited"))

        let draft = try #require(try draft(note, in: context, zone: "Elsewhere"))
        #expect(draft.base == nil, "The copy in Records is not this row.")
        #expect(try self.draft(note, in: context) == nil)
    }

    @Test func aRecordNamedByItsTypeAndIdFindsItsRow() throws {
        let page = Page(id: "intro", title: "Saved")
        try container.save(our: page, zone: "Records")
        let context = RecordContext(container)
        context.insert(Page(id: "intro", title: "Edited"))
        #expect(try draft(page, in: context)?.base == page)
    }
}

private struct Album: Codable, Identifiable {
    var id = UUID()
    var name = ""
    @References<Photo>(inverse: \Photo.albums) var photos: [Photo.ID] = []
}

private struct Photo: Codable, Identifiable {
    var id = UUID()
    @References<Album>(inverse: \Album.photos) var albums: [Album.ID] = []
}

/// `record(_:id:)` reads the open edit first, then the saved value.
@Suite struct RecordContextRecordTests {
    private let container = RecordContainer.inMemory(Note.self, Page.self, Album.self, Photo.self)

    @Test func anOpenEditIsWhatItReads() throws {
        let saved = Note(title: "Saved")
        try container.save(our: saved, zone: "Records")
        let context = RecordContext(container)
        context.insert(Note(id: saved.id, title: "Edited"))
        #expect(context.record(Note.self, id: saved.id)?.title == "Edited")
        #expect(RecordContext(container).record(Note.self, id: saved.id)?.title == "Saved", "Another context sees only what is saved.")
    }

    @Test func aRecordOnlyTheServerHasReads() throws {
        let note = Note(title: "Theirs")
        try container.save(their: JSONRepresentation(note), id: note.id.uuidString, zone: "Records", type: "Note", metadata: nil)
        #expect(RecordContext(container).record(Note.self, id: note.id) == note)
    }

    @Test func unsentChangesWinOverTheServersVersion() throws {
        let note = Note(title: "Theirs")
        try container.save(their: JSONRepresentation(note), id: note.id.uuidString, zone: "Records", type: "Note", metadata: nil)
        try container.save(our: Note(id: note.id, title: "Ours"), zone: "Records")
        #expect(RecordContext(container).record(Note.self, id: note.id)?.title == "Ours")
    }

    @Test func aMissingOrDeletedRecordIsNil() throws {
        let context = RecordContext(container)
        #expect(context.record(Note.self, id: UUID()) == nil)
        let note = Note(title: "Gone")
        try container.save(our: note, zone: "Records")
        try container.delete(our: note, zone: "Records")
        #expect(context.record(Note.self, id: note.id) == nil)
    }

    @Test func aRecordInAnotherZoneIsNil() throws {
        let note = Note(title: "Elsewhere")
        try container.save(our: note, zone: "Elsewhere")
        let context = RecordContext(container)
        #expect(context.record(Note.self, id: note.id) == nil)
        context.zone = "Elsewhere"
        #expect(context.record(Note.self, id: note.id) == note)
    }

    @Test func aValueThatDoesNotDecodeIsNil() throws {
        let id = UUID()
        try container.save(their: ["id": .string(id.uuidString), "title": 3], id: id.uuidString, zone: "Records", type: "Note", metadata: nil)
        #expect(RecordContext(container).record(Note.self, id: id) == nil)
    }

    @Test func relationshipListsComeBackFilled() throws {
        let photo = Photo()
        let album = Album(name: "Trip", photos: [photo.id])
        try container.save(our: photo, zone: "Records")
        try container.save(our: album, zone: "Records")   // after the photo, whose empty list would remove it
        let context = RecordContext(container)
        #expect(context.record(Album.self, id: album.id)?.photos == [photo.id])
        #expect(context.record(Photo.self, id: photo.id)?.albums == [album.id], "The other side fills too.")
    }

    @Test func aStringIdFindsItsRecord() throws {
        try container.save(our: Page(id: "intro", title: "Hello"), zone: "Records")
        #expect(RecordContext(container).record(Page.self, id: "intro")?.title == "Hello")
    }
}
