import Observation
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
        return context.drafts.draft(R.self, at: RecordContainer.RowID(name: name, zone: zone))
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
    @References<Photo>(action: .deleteSelf) var covers: [Photo.ID] = []
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

/// `insert(_:into:at:)` adds a child to a parent's list in the parent's draft.
@Suite struct RecordContextInsertIntoTests {
    private let container = RecordContainer.inMemory(Album.self, Photo.self)

    @Test func aNewChildJoinsASavedParentByItsId() throws {
        let kept = Photo(), album = Album(name: "Trip", photos: [kept.id])
        try container.save(our: kept, zone: "Records")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        let photo = Photo()
        context.insert(photo, into: album.id, at: \Album.photos)

        #expect(context.record(Album.self, id: album.id)?.photos == [kept.id, photo.id])
        #expect(context.record(Photo.self, id: photo.id)?.albums == [album.id], "The child is inserted, listing its parent.")
        #expect(RecordContext(container).record(Album.self, id: album.id)?.photos == [kept.id], "Nothing is saved yet.")
    }

    @Test func aNewParentAndANewChildAreMadeInOneCall() {
        let context = RecordContext(container)
        let album = Album(name: "New"), photo = Photo()
        context.insert(photo, into: album, at: \.photos)
        #expect(context.record(Album.self, id: album.id)?.photos == [photo.id])
        #expect(context.record(Album.self, id: album.id)?.name == "New")
    }

    @Test func aSavedParentWithNoChildrenLearnsItsInverseFromTheChild() throws {
        let album = Album(name: "Empty")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        let photo = Photo()
        context.insert(photo, into: album.id, at: \Album.photos)
        #expect(context.record(Album.self, id: album.id)?.photos == [photo.id])
        #expect(context.record(Photo.self, id: photo.id)?.albums == [album.id])
    }

    @Test func bothSidesSaveTheSameRelationship() throws {
        let context = RecordContext(container)
        let album = Album(name: "Trip"), photo = Photo()
        context.insert(photo, into: album, at: \.photos)
        try container.save(our: try #require(context.record(Photo.self, id: photo.id)), zone: "Records")
        try container.save(our: try #require(context.record(Album.self, id: album.id)), zone: "Records")
        let saved = RecordContext(container)
        #expect(saved.record(Album.self, id: album.id)?.photos == [photo.id], "Saving the album second keeps what the photo saved.")
        #expect(saved.record(Photo.self, id: photo.id)?.albums == [album.id])
    }

    @Test func aFieldListTakesTheChildWithoutTouchingTheChild() throws {
        let first = Photo(), album = Album(name: "Trip", covers: [first.id])
        try container.save(our: first, zone: "Records")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        let photo = Photo()
        context.insert(photo, into: album.id, at: \Album.covers)
        #expect(context.record(Album.self, id: album.id)?.covers == [first.id, photo.id])
        #expect(context.record(Album.self, id: album.id)?.photos == [])
        #expect(context.record(Photo.self, id: photo.id)?.albums == [], "A field list has no other side.")
    }

    @Test func aFieldListOnANewParentSavesOnTheRecord() throws {
        let context = RecordContext(container)
        let album = Album(name: "New"), photo = Photo()
        context.insert(photo, into: album, at: \.covers)
        try container.save(our: try #require(context.record(Album.self, id: album.id)), zone: "Records")
        #expect(RecordContext(container).record(Album.self, id: album.id)?.covers == [photo.id])
        #expect(RecordContext(container).record(Album.self, id: album.id)?.$covers.action == .deleteSelf, "An empty list built in code keeps its declared action.")
    }

    @Test func theParentsOpenEditIsKept() throws {
        let album = Album(name: "Saved")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        context.insert(Album(id: album.id, name: "Renamed"))
        context.insert(Photo(), into: album, at: \.photos)
        #expect(context.record(Album.self, id: album.id)?.name == "Renamed", "The stale value passed in is only used for its id.")
    }

    @Test func aChildAlreadyInTheListIsNotAddedAgain() {
        let context = RecordContext(container)
        let album = Album(), photo = Photo()
        context.insert(photo, into: album, at: \.photos)
        context.insert(photo, into: album.id, at: \Album.photos)
        #expect(context.record(Album.self, id: album.id)?.photos == [photo.id])
    }
}

private struct Shelf: Codable, Identifiable {
    var id = UUID()
}

private struct Book: Codable, Identifiable {
    var id = UUID()
    @Reference<Shelf>(action: .deleteSelf) var shelf: Shelf.ID? = nil
    @Reference<Shelf>(isParent: true) var home: Shelf.ID? = nil
}

/// `insert(_:into:at:)` points a parent's to-one `@Reference` at a child.
@Suite struct RecordContextInsertIntoReferenceTests {
    private let container = RecordContainer.inMemory(Shelf.self, Book.self)

    @Test func aNewParentKeepsTheDeclaredAction() throws {
        let context = RecordContext(container)
        let book = Book(), shelf = Shelf()
        context.insert(shelf, into: book, at: \.shelf)
        let read = try #require(context.record(Book.self, id: book.id))
        #expect(read.shelf == shelf.id)
        #expect(read.$shelf.action == .deleteSelf)
        #expect(context.record(Shelf.self, id: shelf.id) != nil, "The child is inserted too.")
    }

    @Test func aParentReferenceStaysAParent() throws {
        let context = RecordContext(container)
        let book = Book(), shelf = Shelf()
        context.insert(shelf, into: book, at: \.home)
        let read = try #require(context.record(Book.self, id: book.id))
        #expect(read.home == shelf.id)
        #expect(read.$home.isParent)
    }

    @Test func aSavedReferenceIsReplacedKeepingItsAction() throws {
        let old = Shelf(), book = Book(shelf: old.id)
        try container.save(our: old, zone: "Records")
        try container.save(our: book, zone: "Records")
        let context = RecordContext(container)
        let shelf = Shelf()
        context.insert(shelf, into: book.id, at: \Book.shelf)
        let read = try #require(context.record(Book.self, id: book.id))
        #expect(read.shelf == shelf.id)
        #expect(read.$shelf.action == .deleteSelf)
        #expect(RecordContext(container).record(Book.self, id: book.id)?.shelf == old.id, "Nothing is saved yet.")
    }
}

/// `delete(_:)` deletes through ``Drafts``, so other drafts drop the record too.
@Suite struct RecordContextDeleteTests {
    private let container = RecordContainer.inMemory(Page.self, Album.self, Photo.self)

    private func rowID<R>(_ type: R.Type, _ id: some Encodable) throws -> RecordContainer.RowID {
        RecordContainer.RowID(name: try RecordContainer.recordName(for: id, type: RecordContainer.recordType(of: R.self)), zone: "Records")
    }

    @Test func aRecordNeverSavedIsDropped() {
        let context = RecordContext(container)
        let page = Page(id: "draft")
        context.insert(page)
        context.delete(page)
        #expect(context.record(Page.self, id: "draft") == nil)
        #expect(context.drafts.isEmpty, "There is nothing to delete in the database.")
    }

    @Test func aSavedRecordIsMarkedDeletedUntilSave() throws {
        let page = Page(id: "intro", title: "Hello")
        try container.save(our: page, zone: "Records")
        let context = RecordContext(container)
        context.delete(page)
        #expect(context.record(Page.self, id: "intro") == nil)
        let draft = try #require(context.drafts.draft(Page.self, at: rowID(Page.self, "intro")))
        #expect(draft.isDeleted && draft.hasChanges)
        #expect(draft.base == page, "The base is kept for the save.")
        #expect(RecordContext(container).record(Page.self, id: "intro") == page, "Nothing is saved yet.")
    }

    @Test func insertingAgainUndoesTheDelete() throws {
        let page = Page(id: "intro", title: "Hello")
        try container.save(our: page, zone: "Records")
        let context = RecordContext(container)
        context.delete(page)
        context.insert(Page(id: "intro", title: "Back"))
        #expect(context.record(Page.self, id: "intro")?.title == "Back")
        #expect(context.drafts.draft(Page.self, at: try rowID(Page.self, "intro"))?.isDeleted == false)
    }

    @Test func otherDraftsDropTheRecordFromTheirRelationshipLists() throws {
        let kept = Photo(), album = Album(name: "Trip", photos: [kept.id])
        try container.save(our: kept, zone: "Records")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        let added = Photo()
        context.insert(added, into: album.id, at: \Album.photos)
        context.delete(kept)
        #expect(context.record(Album.self, id: album.id)?.photos == [added.id])
        context.delete(added)
        #expect(context.record(Album.self, id: album.id)?.photos == [])
        #expect(context.drafts.count == 2, "The album and the deleted saved photo. The new photo is dropped.")
    }

    @Test func aDeletedParentCannotBeFoundButCanBeInsertedAgain() throws {
        let album = Album(name: "Trip")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        context.delete(album)
        let photo = Photo()
        context.insert(photo, into: album, at: \.photos)
        #expect(context.record(Album.self, id: album.id)?.photos == [photo.id], "Inserting into a deleted parent by value restores it.")
    }

    @Test func aDeleteNotifiesViewsReadingTheContext() {
        let context = RecordContext(container)
        let page = Page(id: "draft")
        context.insert(page)
        nonisolated(unsafe) var notified = false
        withObservationTracking { _ = context.record(Page.self, id: "draft") } onChange: { notified = true }
        context.delete(page)
        #expect(notified)
    }
}
