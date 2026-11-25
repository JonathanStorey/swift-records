import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Tag: Codable, Identifiable, Mergeable {
    var id = UUID()
    var name = ""
    @References<Note>(inverse: \Note.tags) var notes: [Note.ID] = []
}

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title = ""
    @References<Tag>(inverse: \Tag.notes) var tags: [Tag.ID] = []
    @References<Tag>(inverse: \Tag.notes) var archived: [Tag.ID] = []
    @Reference<Folder> var folder: Folder.ID? = nil
}

private struct Folder: Codable, Identifiable, Mergeable {
    var id: String
}

private struct Person: Codable, Identifiable, Mergeable {
    var id: String
    @References<Person>(inverse: \Person.friends) var friends: [Person.ID] = []
}

/// Identified by an `Int` and a `String`.
private struct Shelf: Codable, Identifiable, Mergeable {
    var id: Int
    @References<Book>(inverse: \Book.shelves) var books: [Book.ID] = []
}

private struct Book: Codable, Identifiable, Mergeable {
    var id: String
    @References<Shelf>(inverse: \Shelf.books) var shelves: [Shelf.ID] = []
}

/// `@References(inverse:)` lists stored as ``Relationship`` records: saved apart from their
/// record and filled back in when it is fetched, from either side.
@Suite struct RecordContainerRelationshipTests {
    private let notes = Zone("Notes")
    private let container = RecordContainer.inMemory(Note.self, Tag.self, Folder.self, Person.self, Shelf.self, Book.self)
    private let swift = Tag(name: "Swift"), sql = Tag(name: "SQL"), web = Tag(name: "Web")

    private func relationships() throws -> [Relationship] {
        try container.fetch(Relationship.self, in: notes).sorted { ($0.orders[0] ?? .max) < ($1.orders[0] ?? .max) }
    }

    private func note(_ id: UUID) throws -> Note? {
        try container.fetch(Note.self, in: notes).first { $0.id == id }
    }

    @Test func aListIsSavedAsRelationshipsAndNotOnTheRecord() throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id])
        try container.save(our: note, zone: notes)

        let row = try #require(try container.row(id: note.id))
        #expect(row.ours?["tags"] == nil)
        let saved = try relationships()
        #expect(saved.map(\.references) == [[note.id.uuidString, swift.id.uuidString], [note.id.uuidString, sql.id.uuidString]])
        #expect(saved.map(\.keyPaths) == [["Note.tags", "Tag.notes"], ["Note.tags", "Tag.notes"]])
        #expect(saved.map(\.orders) == [[0, nil], [1, nil]])
        #expect(try container.row(id: RecordContainer.RowID(name: saved[0].id, zone: notes)) != nil, "A relationship is saved under its id.")
    }

    @Test func fetchingFillsTheListInOrder() throws {
        let note = Note(title: "Hello", tags: [sql.id, swift.id])
        try container.save(our: note, zone: notes)

        let fetched = try #require(try self.note(note.id))
        #expect(fetched.tags == [sql.id, swift.id])
        #expect(fetched.$tags.storage == .relationships)
        #expect(fetched.$tags.zone == notes)
    }

    @Test func fetchingFillsTheOtherSide() throws {
        let first = Note(title: "First", tags: [swift.id]), second = Note(title: "Second", tags: [swift.id, sql.id])
        try container.save(our: swift, zone: notes)
        try container.save(our: first, zone: notes)
        try container.save(our: second, zone: notes)

        let tag = try #require(try container.fetch(Tag.self, in: notes).first)
        #expect(Set(tag.notes) == [first.id, second.id])
        #expect(tag.$notes.storage == .relationships)
    }

    @Test func aPredicateFindsEveryRecordWithATarget() throws {
        try container.save(our: Note(title: "Tagged", tags: [sql.id, swift.id]), zone: notes)
        try container.save(our: Note(title: "Other", tags: [sql.id]), zone: notes)
        try container.save(our: Note(title: "Plain"), zone: notes)
        let tagID = swift.id

        let titles = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.tags.contains(tagID) }).map(\.title)
        #expect(titles == ["Tagged"])
    }

    @Test func eitherSideSavesTheSameRelationship() throws {
        let note = Note(title: "Hello")
        try container.save(our: note, zone: notes)
        try container.save(our: Tag(id: swift.id, name: "Swift", notes: [note.id]), zone: notes)

        let saved = try relationships()
        #expect(saved.map(\.id) == [Relationship(between: ("Note.tags", note.id.uuidString), and: ("Tag.notes", swift.id.uuidString)).id])
        #expect(saved.first?.orders == [nil, 0], "Each side places the relationship only in its own list.")
        #expect(try self.note(note.id)?.tags == [swift.id])
    }

    @Test func removingATargetDeletesOnlyItsRelationshipAndRenumbersNothing() throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id, web.id])
        try container.save(our: note, zone: notes)
        try container.save(our: Note(id: note.id, title: "Hello", tags: [swift.id, web.id]), zone: notes)

        let saved = try relationships()
        #expect(saved.map { $0.target(from: note.id.uuidString, keyPath: "Note.tags") } == [swift.id.uuidString, web.id.uuidString])
        #expect(saved.map(\.orders) == [[0, nil], [2, nil]])
        #expect(try self.note(note.id)?.tags == [swift.id, web.id])
    }

    @Test func movingATargetPlacesItAfterThoseBefore() throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id, web.id])
        try container.save(our: note, zone: notes)
        try container.save(our: Note(id: note.id, title: "Hello", tags: [sql.id, swift.id, web.id]), zone: notes)

        #expect(try self.note(note.id)?.tags == [sql.id, swift.id, web.id])
    }

    @Test func savingAnUnchangedListWritesNoRelationships() async throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id])
        try container.save(our: note, zone: notes)
        var transactions = container.transactions().makeAsyncIterator()
        try container.save(our: Note(id: note.id, title: "Edited", tags: [swift.id, sql.id]), zone: notes)

        let transaction = try #require(await transactions.next())
        #expect(transaction.changes.map(\.id.name) == [note.id.uuidString])
    }

    @Test func aRelationshipChangeReportsTheRecordOnEachSide() async throws {
        let note = Note(title: "Hello", tags: [swift.id])
        let relationship = Relationship(between: ("Note.tags", note.id.uuidString), and: ("Tag.notes", swift.id.uuidString))
        var transactions = container.transactions().makeAsyncIterator()
        try container.save(our: note, zone: notes)
        let added = try #require(await transactions.next())
        #expect(added.changes == [
            .inserted(RecordContainer.RowID(name: note.id.uuidString, zone: notes), type: "Note"),
            .inserted(RecordContainer.RowID(name: relationship.id, zone: notes), type: "Relationship"),
            .updated(RecordContainer.RowID(name: swift.id.uuidString, zone: notes), type: "Tag"),
        ], "The tag's list changed, though its row did not. The note is listed once.")

        try container.save(our: Note(id: note.id, title: "Hello"), zone: notes)
        let removed = try #require(await transactions.next())
        #expect(removed.changes.map(\.id.name) == [note.id.uuidString, relationship.id, swift.id.uuidString])
        #expect(removed.changes.dropFirst().first == .deleted(RecordContainer.RowID(name: relationship.id, zone: notes), type: "Relationship"))
    }

    @Test func aRecordChangedInTheSameTransactionKeepsItsOwnChange() async throws {
        let note = Note(title: "Hello")
        try container.save(our: note, zone: notes)
        var transactions = container.transactions().makeAsyncIterator()
        try container.delete(our: note, zone: notes)
        try container.save(our: Tag(id: swift.id, name: "Swift", notes: [note.id]), zone: notes)
        _ = try #require(await transactions.next())
        let tagged = try #require(await transactions.next())
        #expect(tagged.changes.first == .inserted(RecordContainer.RowID(name: swift.id.uuidString, zone: notes), type: "Tag"))
        #expect(tagged.changes.last == .updated(RecordContainer.RowID(name: note.id.uuidString, zone: notes), type: "Note"), "The other side is reported even when its row is gone.")
        #expect(tagged.changes.count == 3)
    }

    @Test func emptyingAListDeletesItsRelationships() throws {
        let note = Note(title: "Hello", tags: [swift.id])
        try container.save(our: note, zone: notes)
        try container.save(our: Note(id: note.id, title: "Hello"), zone: notes)

        #expect(try relationships().isEmpty)
    }

    @Test func aRecordFetchedWithNoRelationshipsSavesWithoutTouchingOthers() throws {
        let note = Note(title: "Hello")
        try container.save(our: note, zone: notes)
        let fetched = try #require(try self.note(note.id))
        try container.save(our: Tag(id: swift.id, notes: [note.id]), zone: notes)
        try container.save(our: fetched, zone: notes)

        #expect(try relationships().count == 1, "A list decoded from a missing key cannot tell its storage, so saving it writes nothing.")
    }

    @Test func deletingARecordDeletesItsRelationships() throws {
        let note = Note(title: "Hello", tags: [swift.id, sql.id]), other = Note(title: "Other", tags: [swift.id])
        try container.save(our: note, zone: notes)
        try container.save(our: other, zone: notes)
        try container.delete(our: note, zone: notes)

        #expect(try relationships().map(\.references) == [[other.id.uuidString, swift.id.uuidString]])
        #expect(try container.fetch(Tag.self, in: notes).isEmpty)
    }

    @Test func aPropertyPairedWithTwoInversesThrows() throws {
        let note = Note(title: "Hello", tags: [swift.id])
        try container.save(our: note, zone: notes)

        #expect(throws: RecordError.self, "Tag.notes points back at Note.tags, so Note.archived cannot also claim it.") {
            try container.save(our: Note(id: note.id, title: "Hello", tags: [swift.id], archived: [swift.id]), zone: notes)
        }
        #expect(try relationships().count == 1, "Nothing is saved.")
    }

    @Test func aPropertyWhoseRelationshipsPairWithAnotherInverseThrows() throws {
        let note = Note(title: "Hello")
        try container.save(our: note, zone: notes)
        // As left by an earlier version of the app that named another inverse.
        try container.save(our: Relationship(between: ("Note.archived", note.id.uuidString), and: ("Tag.labels", swift.id.uuidString)), zone: notes)

        #expect(throws: RecordError.self, "Note.archived already pairs with Tag.labels, not Tag.notes.") {
            try container.save(our: Note(id: note.id, title: "Hello", archived: [sql.id]), zone: notes)
        }
        #expect(try relationships().count == 1, "Nothing is saved.")
    }

    @Test func aListThatLostItsInverseThrows() throws {
        let note = Note(title: "Hello")
        // A relationship list decoded from data without its inverse.
        guard case .object(var object) = try JSONRepresentation(note) else { Issue.record("A note encodes as an object."); return }
        object.removeAll { $0.key == "tags" }
        object.append(("tags", ["$relationships": [["recordName": .string(swift.id.uuidString), "action": "none"]]]))
        let damaged = try JSONRepresentation.object(object).decode(Note.self)

        #expect(throws: RecordError.self) { try container.save(our: damaged, zone: notes) }
        #expect(try relationships().isEmpty)
    }

    @Test func relationshipsSortByOrderWithUnplacedOnesLast() throws {
        let note = Note(title: "Hello")
        try container.save(our: note, zone: notes)
        for (tag, order) in [(swift, 4), (sql, nil), (web, 0)] as [(Tag, Int?)] {
            var relationship = Relationship(between: ("Note.tags", note.id.uuidString), and: ("Tag.notes", tag.id.uuidString))
            relationship[orderIn: note.id.uuidString, keyPath: "Note.tags"] = order
            try container.save(our: relationship, zone: notes)
        }

        #expect(try self.note(note.id)?.tags == [web.id, swift.id, sql.id])
    }

    @Test func aSymmetricRelationshipFillsBothFriends() throws {
        try container.save(our: Person(id: "bob"), zone: notes)
        try container.save(our: Person(id: "alice", friends: ["bob"]), zone: notes)

        let people = try container.fetch(Person.self, in: notes, order: [SortDescriptor(\.id)])
        #expect(people.map(\.friends) == [["bob"], ["alice"]])
        #expect(try relationships().map(\.keyPaths) == [["Person.friends", "Person.friends"]])
    }

    @Test func aRecordInItsOwnSymmetricListIsListedOnce() throws {
        try container.save(our: Person(id: "alice", friends: ["alice"]), zone: notes)

        #expect(try container.fetch(Person.self, in: notes).first?.friends == ["alice"])
    }

    @Test func intAndStringIDsRelateBothWays() throws {
        try container.save(our: Shelf(id: 1), zone: notes)
        try container.save(our: Book(id: "Swift", shelves: [1]), zone: notes)

        #expect(try container.fetch(Shelf.self, in: notes).first?.books == ["Swift"])
        #expect(try relationships().first?.references == ["Book:Swift", "Shelf:1"])
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

        #expect(throws: RecordError.referenceOutsideZone(reference: "Folder:inbox", zone: "Other")) { try container.save(our: fetched, zone: "Other") }
        #expect(try container.fetch(Note.self, in: "Other").isEmpty)
    }
}
