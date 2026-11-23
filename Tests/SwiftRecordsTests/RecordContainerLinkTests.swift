import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Tag: Codable, Identifiable, Mergeable {
    var id = UUID()
    var name = ""
    @References<Note>(from: \Note.tags) var notes: [Note.ID] = []
}

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title = ""
    @References<Tag>(to: \Tag.notes) var tags: [Tag.ID] = []
    @Reference<Folder> var folder: Folder.ID? = nil
}

private struct Folder: Codable, Identifiable, Mergeable {
    var id: String
}

/// Identified by an `Int` and a `String`.
private struct Shelf: Codable, Identifiable, Mergeable {
    var id: Int
    @References<Book>(from: \Book.shelves) var books: [Book.ID] = []
}

private struct Book: Codable, Identifiable, Mergeable {
    var id: String
    @References<Shelf>(to: \Shelf.books) var shelves: [Shelf.ID] = []
}

/// `@References` lists stored as ``Relationship`` records: saved apart from their record and
/// filled back in when it is fetched, from either side.
@Suite struct RecordContainerLinkTests {
    private let notes = Zone("Notes")
    private let container = RecordContainer.inMemory(Note.self, Tag.self, Folder.self, Shelf.self, Book.self)
    private let swift = Tag(name: "Swift"), sql = Tag(name: "SQL"), web = Tag(name: "Web")

    private func links() throws -> [Relationship] {
        try container.fetch(Relationship.self, in: notes, order: [SortDescriptor(\.order)])
    }

    @Test func aListIsSavedAsLinksAndNotOnTheRecord() throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id])
        try container.save(our: note, zone: notes)

        let row = try #require(try container.row(id: note.id))
        #expect(row.ours?["tags"] == nil)
        let saved = try links()
        #expect(saved.map(\.references) == [[note.id.uuidString, swift.id.uuidString], [note.id.uuidString, sql.id.uuidString]])
        #expect(saved.map(\.keyPath) == ["Note.tags", "Note.tags"])
        #expect(saved.map(\.inverseKeyPath) == ["Tag.notes", "Tag.notes"])
        #expect(saved.map(\.order) == [0, 1])
    }

    @Test func fetchingFillsTheListInOrder() throws {
        let note = Note(title: "Hello", tags: [sql.id, swift.id])
        try container.save(our: note, zone: notes)

        let fetched = try #require(try container.fetch(Note.self, in: notes).first)
        #expect(fetched.tags == [sql.id, swift.id])
        #expect(fetched.$tags.storage == .links)
        #expect(fetched.$tags.zone == notes)
    }

    @Test func fetchingFillsTheInverse() throws {
        let first = Note(title: "First", tags: [swift.id]), second = Note(title: "Second", tags: [swift.id, sql.id])
        try container.save(our: swift, zone: notes)
        try container.save(our: first, zone: notes)
        try container.save(our: second, zone: notes)

        let tag = try #require(try container.fetch(Tag.self, in: notes).first)
        #expect(Set(tag.notes) == [first.id, second.id])
        #expect(tag.$notes.storage == .inverse)
    }

    @Test func aPredicateFindsEveryRecordWithATarget() throws {
        try container.save(our: Note(title: "Tagged", tags: [sql.id, swift.id]), zone: notes)
        try container.save(our: Note(title: "Other", tags: [sql.id]), zone: notes)
        try container.save(our: Note(title: "Plain"), zone: notes)
        let tag = swift.id

        let titles = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.tags.contains(tag) }).map(\.title)
        #expect(titles == ["Tagged"])
    }

    @Test func savingTheInverseWritesTheSameLinks() throws {
        let note = Note(title: "Hello")
        try container.save(our: note, zone: notes)
        try container.save(our: Tag(id: swift.id, name: "Swift", notes: [note.id]), zone: notes)

        let saved = try links()
        #expect(saved.map(\.references) == [[note.id.uuidString, swift.id.uuidString]], "The link is named by the declaring side either way.")
        #expect(saved.first?.keyPath == "Note.tags")
        #expect(saved.first?.order == nil, "The inverse places the link only in its own list.")
        #expect(saved.first?.inverseOrder == 0)
        #expect(try container.fetch(Note.self, in: notes).first?.tags == [swift.id])
    }

    @Test func removingATargetDeletesOnlyItsLinkAndRenumbersNothing() throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id, web.id])
        try container.save(our: note, zone: notes)
        try container.save(our: Note(id: note.id, title: "Hello", tags: [swift.id, web.id]), zone: notes)

        let saved = try links()
        #expect(saved.map { $0.target(from: note.id.uuidString) } == [swift.id.uuidString, web.id.uuidString])
        #expect(saved.map(\.order) == [0, 2])
        #expect(try container.fetch(Note.self, in: notes).first?.tags == [swift.id, web.id])
    }

    @Test func movingATargetPlacesItAfterThoseBefore() throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id, web.id])
        try container.save(our: note, zone: notes)
        try container.save(our: Note(id: note.id, title: "Hello", tags: [sql.id, swift.id, web.id]), zone: notes)

        #expect(try container.fetch(Note.self, in: notes).first?.tags == [sql.id, swift.id, web.id])
    }

    @Test func savingAnUnchangedListWritesNoLinks() async throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id])
        try container.save(our: note, zone: notes)
        var transactions = container.transactions().makeAsyncIterator()
        try container.save(our: Note(id: note.id, title: "Edited", tags: [swift.id, sql.id]), zone: notes)

        let transaction = try #require(await transactions.next())
        #expect(transaction.changes.map(\.id.name) == [note.id.uuidString])
    }

    @Test func emptyingAListDeletesItsLinks() throws {
        let note = Note(title: "Hello", tags: [swift.id])
        try container.save(our: note, zone: notes)
        try container.save(our: Note(id: note.id, title: "Hello"), zone: notes)

        #expect(try links().isEmpty)
    }

    @Test func aRecordFetchedWithNoLinksSavesWithoutTouchingOthersLinks() throws {
        let note = Note(title: "Hello")
        try container.save(our: note, zone: notes)
        let fetched = try #require(try container.fetch(Note.self, in: notes).first)
        try container.save(our: Tag(id: swift.id, notes: [note.id]), zone: notes)
        try container.save(our: fetched, zone: notes)

        #expect(try links().count == 1, "A list decoded from a missing key cannot tell its storage, so saving it writes nothing.")
    }

    @Test func linksSortByOrderWithUnplacedLinksLast() throws {
        let note = Note(title: "Hello")
        try container.save(our: note, zone: notes)
        for (tag, order) in [(swift, 4), (sql, nil), (web, 0)] as [(Tag, Int?)] {
            var link = Relationship(keyPath: "Note.tags", from: note.id, to: tag.id)
            link.order = order
            link.inverseKeyPath = "Tag.notes"
            try container.save(our: link, zone: notes)
        }

        #expect(try container.fetch(Note.self, in: notes).first?.tags == [web.id, swift.id, sql.id])
    }

    @Test func intAndStringIDsLinkBothWays() throws {
        try container.save(our: Shelf(id: 1), zone: notes)
        try container.save(our: Book(id: "Swift", shelves: [1]), zone: notes)

        #expect(try container.fetch(Shelf.self, in: notes).first?.books == ["Swift"])
        #expect(try links().first?.references == ["Book:Swift", "Shelf:1"])
    }

    @Test func aReferenceIsPlacedInItsRecordsZone() throws {
        try container.save(our: Note(title: "Filed", folder: "inbox"), zone: notes)

        let fetched = try #require(try container.fetch(Note.self, in: notes).first)
        #expect(fetched.folder == "inbox")
        #expect(fetched.$folder.zone == notes)
    }

    @Test func aReferenceIntoAnotherZoneThrowsAndSavesNothing() throws {
        try container.save(our: Note(title: "Filed", folder: "inbox"), zone: notes)
        let fetched = try #require(try container.fetch(Note.self, in: notes).first)

        #expect(throws: EncodingError.self) { try container.save(our: fetched, zone: "Other") }
        #expect(try container.fetch(Note.self, in: "Other").isEmpty)
    }
}
