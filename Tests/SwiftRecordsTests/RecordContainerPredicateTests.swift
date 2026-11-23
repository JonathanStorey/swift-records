import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Tag: Codable, Identifiable, Mergeable {
    var id = UUID()
    @References<Note>(inverse: \Note.tags) var notes: [Note.ID] = []
}

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title = ""
    var rank = 0
    var due: Date? = nil
    var isPinned = false
    @References<Tag>(inverse: \Tag.notes) var tags: [Tag.ID] = []

    /// Computed, so SQL cannot read it.
    var isUrgent: Bool { rank > 5 }

    enum CodingKeys: String, CodingKey {
        case id, rank, due, isPinned, tags
        case title = "heading"
    }
}

/// `#Predicate` translated to SQL that narrows the rows `fetch` decodes.
@Suite struct RecordContainerPredicateTests {
    private let zone = Zone("Notes")
    private let container = RecordContainer.inMemory(Note.self, Tag.self)
    private let swift = Tag(), sql = Tag()
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let notes: [Note]

    init() {
        notes = [
            Note(title: "Alpha", rank: 1, due: start, isPinned: true, tags: [swift.id]),
            Note(title: "Beta", rank: 5, tags: [sql.id]),
            Note(title: "Gamma", rank: 9, due: start.addingTimeInterval(60), tags: [swift.id, sql.id]),
        ]
    }

    private func save() throws {
        for note in notes { try container.save(our: note, zone: zone) }
    }

    /// The titles SQL alone keeps, with no predicate run in Swift.
    private func titles(_ predicate: Predicate<Note>) throws -> [String] {
        let filter = try #require(RecordContainer.filter(for: predicate))
        return try container.fetch(Note.self, in: zone, where: filter).map(\.title).sorted()
    }

    /// The titles `predicate` accepts.
    private func fetched(_ predicate: Predicate<Note>) throws -> [String] {
        try container.fetch(Note.self, in: zone, predicate: predicate).map(\.title).sorted()
    }

    @Test func comparisonsReadTheStoredJSON() throws {
        try save()
        #expect(try titles(#Predicate { $0.title == "Beta" }) == ["Beta"], "The path follows CodingKeys.")
        #expect(try titles(#Predicate { $0.title != "Beta" }) == ["Alpha", "Gamma"])
        #expect(try titles(#Predicate { $0.rank >= 5 }) == ["Beta", "Gamma"])
        #expect(try titles(#Predicate { $0.title < "B" }) == ["Alpha"])
        let later = start.addingTimeInterval(30)
        #expect(try titles(#Predicate { $0.due != nil }) == ["Alpha", "Gamma"])
        #expect(try titles(#Predicate { $0.due == nil }) == ["Beta"])
        #expect(try titles(#Predicate { $0.due == later }) == [])
    }

    @Test func aBoolIsReadThroughItsFlag() throws {
        try save()
        #expect(try titles(#Predicate { $0.isPinned }) == ["Alpha"])
        #expect(try titles(#Predicate { !$0.isPinned }) == ["Beta", "Gamma"])
        #expect(try titles(#Predicate { $0.isPinned == false }) == ["Beta", "Gamma"])
    }

    @Test func logicCombinesThePieces() throws {
        try save()
        #expect(try titles(#Predicate { $0.rank > 1 && $0.title != "Gamma" }) == ["Beta"])
        #expect(try titles(#Predicate { $0.rank == 1 || $0.rank == 9 }) == ["Alpha", "Gamma"])
        #expect(try titles(#Predicate { !($0.rank == 5) }) == ["Alpha", "Gamma"])
    }

    @Test func aCapturedListFindsItsRows() throws {
        try save()
        let ids = [notes[0].id, notes[2].id], ranks = [5, 9]
        #expect(try titles(#Predicate { ids.contains($0.id) }) == ["Alpha", "Gamma"])
        #expect(try titles(#Predicate { ranks.contains($0.rank) }) == ["Beta", "Gamma"])
    }

    @Test func aRelationshipListFindsItsTarget() throws {
        try save()
        let tag = sql.id
        #expect(try titles(#Predicate { $0.tags.contains(tag) }) == ["Beta", "Gamma"])
    }

    @Test func whatSQLCannotReadIsLeftToSwift() throws {
        try save()
        let filter = RecordContainer.filter(for: #Predicate<Note> { $0.isUrgent })
        #expect(filter == nil, "A computed property has no stored value.")
        let partial = try #require(RecordContainer.filter(for: #Predicate<Note> { $0.isUrgent && $0.title != "Alpha" }))
        #expect(!partial.isExact, "One side of && still narrows, but loosely.")
        #expect(try fetched(#Predicate { $0.isUrgent && $0.title != "Alpha" }) == ["Gamma"])
        let negated = RecordContainer.filter(for: #Predicate<Note> { !($0.isUrgent && $0.title != "Alpha") })
        #expect(negated == nil, "A loose condition cannot be negated.")
        let either = RecordContainer.filter(for: #Predicate<Note> { $0.isUrgent || $0.rank == 1 })
        #expect(either == nil, "|| needs both sides.")
        #expect(try fetched(#Predicate { $0.isUrgent || $0.rank == 1 }) == ["Alpha", "Gamma"])
    }

    @Test func relationshipsAreReadOnlyForTheKeptRows() throws {
        try save()
        let filter = try #require(RecordContainer.filter(for: #Predicate<Note> { $0.rank == 5 }))
        let lists = try container.relationshipLists(in: zone, type: "Note", where: filter)
        #expect(Set(lists.keys) == [notes[1].id.uuidString])
        #expect(try container.fetch(Note.self, in: zone, predicate: #Predicate { $0.rank == 5 }).first?.tags == [sql.id])
        #expect(try container.relationshipLists(in: zone, type: "Tag").count == 2, "Each tag lists its notes.")
    }
}
