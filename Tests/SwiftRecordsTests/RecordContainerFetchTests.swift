import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Address: Codable, Hashable {
    var city: String
    var zip: String?
}

private struct Folder: Codable, Identifiable, Mergeable {
    var id = UUID()
    var name = ""
}

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title = ""
    var rank = 0
    var tags: [String] = []
    var address: Address? = nil
    var stops: [Address] = []
    @Reference var folder: RecordID<Folder>? = nil
    @References var related: [RecordID<Folder>] = []
    @Asset var picture: Data? = nil
}

/// `fetch(_:in:predicate:order:)`: one type in one zone, filtered by a `#Predicate` and
/// sorted by `SortDescriptor`s, on every platform.
@Suite struct RecordContainerFetchTests {
    private let notes = Zone("Notes")
    private let container = RecordContainer.inMemory(Note.self, Folder.self)

    private func save(_ records: Note...) throws {
        for record in records { try container.save(our: record, zone: notes) }
    }

    @Test func returnsEveryValueOfTheTypeInTheZone() throws {
        let first = Note(title: "First"), second = Note(title: "Second")
        try save(first, second)
        try container.save(our: Note(title: "Elsewhere"), zone: "Other")
        try container.save(our: Folder(name: "Not a note"), zone: notes)

        let titles = try container.fetch(Note.self, in: notes).map(\.title)
        #expect(Set(titles) == ["First", "Second"])
    }

    @Test func aSharedZoneWithTheSameNameIsAnotherZone() throws {
        try save(Note(title: "Mine"))
        try container.save(our: Note(title: "Theirs"), zone: Zone("Notes", owner: "_friend"))

        #expect(try container.fetch(Note.self, in: notes).map(\.title) == ["Mine"])
        #expect(try container.fetch(Note.self, in: Zone("Notes", owner: "_friend")).map(\.title) == ["Theirs"])
    }

    @Test func prefersOursOverTheServersVersion() throws {
        var note = Note(title: "Server")
        try container.save(their: JSONRepresentation(note), id: note.id, zone: notes, type: "Note", metadata: Data([1]))
        #expect(try container.fetch(Note.self, in: notes).map(\.title) == ["Server"])

        note.title = "Mine"
        try save(note)
        #expect(try container.fetch(Note.self, in: notes).map(\.title) == ["Mine"])
    }

    @Test func leavesOutDeletedRows() throws {
        let kept = Note(title: "Kept"), deleted = Note(title: "Deleted")
        try save(kept)
        try container.save(their: JSONRepresentation(deleted), id: deleted.id, zone: notes, type: "Note", metadata: Data([1]))
        try container.delete(our: deleted, zone: notes)

        #expect(try container.row(id: RecordContainer.RowID(name: deleted.id, zone: notes))?.isDeleted == true)
        #expect(try container.fetch(Note.self, in: notes).map(\.title) == ["Kept"])
    }

    @Test func skipsARowThatDoesNotDecode() throws {
        try save(Note(title: "Readable"))
        let id = UUID()
        try container.save(their: ["id": .string(id.uuidString), "title": 5], id: id, zone: notes, type: "Note", metadata: Data([1]))

        #expect(try container.fetch(Note.self, in: notes).map(\.title) == ["Readable"])
    }

    @Test func filtersByATopLevelValue() throws {
        try save(Note(title: "Low", rank: 1), Note(title: "High", rank: 9))
        let minimum = 5

        let titles = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.rank >= minimum }).map(\.title)
        #expect(titles == ["High"])
    }

    @Test func filtersByANestedOptionalValue() throws {
        try save(Note(title: "Paris", address: Address(city: "Paris")), Note(title: "Rome", address: Address(city: "Rome", zip: "00100")), Note(title: "Nowhere"))
        let city = "Rome"

        let byCity = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.address?.city == city })
        #expect(byCity.map(\.title) == ["Rome"])
        let withZip = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.address?.zip != nil })
        #expect(withZip.map(\.title) == ["Rome"])
    }

    @Test func filtersByAnArray() throws {
        try save(Note(title: "Tagged", tags: ["swift", "data"]), Note(title: "Plain"))
        let tag = "swift"

        let titles = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.tags.contains(tag) }).map(\.title)
        #expect(titles == ["Tagged"])
    }

    @Test func filtersByAValueInsideAnArrayOfStructs() throws {
        try save(Note(title: "Tour", stops: [Address(city: "Paris"), Address(city: "Rome")]), Note(title: "Home", stops: [Address(city: "Paris")]))

        let titles = try container.fetch(Note.self, in: notes, predicate: #Predicate { note in
            note.stops.contains { $0.city == "Rome" }
        }).map(\.title)
        #expect(titles == ["Tour"])
    }

    @Test func filtersByAReference() throws {
        let folder = RecordID<Folder>(name: UUID(), zone: notes)
        try save(Note(title: "Filed", folder: folder), Note(title: "Loose"))
        let wanted: RecordID<Folder>? = folder

        let titles = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.folder == wanted }).map(\.title)
        #expect(titles == ["Filed"])
    }

    @Test func filtersByReferences() throws {
        let folder = RecordID<Folder>(name: UUID(), zone: notes)
        try save(Note(title: "Linked", related: [RecordID(name: UUID(), zone: notes), folder]), Note(title: "Unlinked"))

        let titles = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.related.contains(folder) }).map(\.title)
        #expect(titles == ["Linked"])
    }

    @Test func fetchesRelationshipsByKeyPathAndRecord() throws {
        let note = UUID().uuidString, tag = UUID().uuidString, other = UUID().uuidString
        try container.save(our: Relationship(keyPath: "Note.tags", from: note, to: tag), zone: notes)
        try container.save(our: Relationship(keyPath: "Note.tags", from: other, to: tag), zone: notes)
        try container.save(our: Relationship(keyPath: "Note.links", from: note, to: other), zone: notes)
        let keyPath = "Note.tags"

        let links = try container.fetch(Relationship.self, in: notes, predicate: #Predicate {
            $0.keyPath == keyPath && $0.references.contains(note)
        })
        #expect(links.map { $0.target(from: note) } == [tag])
    }

    @Test func readsTheContainersCopyOfAnAsset() throws {
        try save(Note(title: "Photo", picture: Data([1, 2, 3])))

        let fetched = try #require(try container.fetch(Note.self, in: notes).first)
        #expect(fetched.picture == Data([1, 2, 3]))
    }

    @Test func sortsByEachDescriptorInTurn() throws {
        try save(Note(title: "B", rank: 1), Note(title: "A", rank: 2), Note(title: "C", rank: 1))

        let byRank = try container.fetch(Note.self, in: notes, order: [SortDescriptor(\.rank, order: .reverse), SortDescriptor(\.title)])
        #expect(byRank.map(\.title) == ["A", "B", "C"])
    }

    @Test func filtersThenSorts() throws {
        try save(Note(title: "B", rank: 3), Note(title: "A", rank: 2), Note(title: "C", rank: 0))

        let titles = try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.rank > 0 }, order: [SortDescriptor(\.title)]).map(\.title)
        #expect(titles == ["A", "B"])
    }

    @Test func aPredicateThatThrowsThrows() throws {
        try save(Note(title: "Nowhere"))

        #expect(throws: (any Error).self) {
            try container.fetch(Note.self, in: notes, predicate: #Predicate { $0.address!.city == "Rome" })
        }
    }

    @Test func anEmptyZoneReturnsNothing() throws {
        #expect(try container.fetch(Note.self, in: notes).isEmpty)
    }
}
