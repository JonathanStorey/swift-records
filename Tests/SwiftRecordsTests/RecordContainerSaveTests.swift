import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title: String
}

/// A plain struct, identified by `slug`.
private struct Page: Codable, Mergeable {
    var slug: String
    var title = ""
}

private struct Chapter: Codable, Mergeable {
    var slug: String
}

private func recordID<Record: Encodable, ID: Encodable>(of record: Record, id: KeyPath<Record, ID>) throws -> UUID {
    try RecordContainer.recordID(for: record[keyPath: id], type: RecordContainer.recordType(of: Record.self))
}

@Suite struct RecordContainerSaveTests {
    @Test func aUUIDIDIsTheRecordID() throws {
        let note = Note(title: "Draft")
        #expect(try recordID(of: note, id: \.id) == note.id)
    }

    @Test func anyOtherIDHashesWithItsType() throws {
        let id = try recordID(of: Page(slug: "intro"), id: \.slug)
        #expect(try recordID(of: Page(slug: "intro", title: "Changed"), id: \.slug) == id)
        #expect(try recordID(of: Page(slug: "outro"), id: \.slug) != id)
        #expect(try recordID(of: Chapter(slug: "intro"), id: \.slug) != id)
        #expect(id == UUID(stableHashOf: #"Page|"intro""#))
    }

    @Test func aPlainStructSavesUnderTheHashOfItsID() throws {
        let container = RecordContainer()
        try container.save(our: Page(slug: "intro", title: "First"), id: \.slug, zone: "Notes")
        try container.save(our: Page(slug: "intro", title: "Second"), id: \.slug, zone: "Notes")

        let row = try #require(try container.row(id: recordID(of: Page(slug: "intro"), id: \.slug)))
        #expect(row.ours == ["slug": "intro", "title": "Second"])
    }

    @Test func anotherKeyPathSavesAnotherRow() throws {
        let container = RecordContainer()
        let page = Page(slug: "intro", title: "Welcome")
        try container.save(our: page, id: \.slug, zone: "Notes")
        try container.save(our: page, id: \.title, zone: "Notes")

        #expect(try container.row(id: recordID(of: page, id: \.slug)) != nil)
        #expect(try container.row(id: recordID(of: page, id: \.title)) != nil)
    }

    @Test func aNewRecordIsWaitingToUpload() throws {
        let container = RecordContainer()
        let note = Note(title: "Draft")
        try container.save(our: note, zone: "Notes")

        let row = try #require(try container.row(id: note.id))
        #expect(row == RecordContainer.Row(id: note.id, zone: "Notes", type: "Note", ours: ["id": .string(note.id.uuidString), "title": "Draft"]))
        #expect(row.status == .waitingToUpload)
    }

    @Test func savingAgainReplacesOursAndKeepsTheRest() throws {
        let container = RecordContainer()
        var note = Note(title: "First")
        try container.save(our: note, zone: "Notes")
        try container.execute("UPDATE record SET base = '{\"title\":\"Base\"}', is_deleted = 1, error = 'Record too large'")

        note.title = "Second"
        try container.save(our: note, zone: Zone("Elsewhere", owner: "someone"))

        let row = try #require(try container.row(id: note.id))
        #expect(row.ours?["title"] == "Second")
        #expect(row.base == ["title": "Base"])
        #expect(row.zone == "Notes", "A record never moves zones.")
        #expect(!row.isDeleted)
        #expect(row.error == nil)
    }

    @Test func updateChangesAnExistingRowOnly() throws {
        let container = RecordContainer()
        let note = Note(title: "Draft")
        try container.save(our: note, zone: "Notes")
        try container.update(id: note.id) { $0.error = "Record too large" }
        let unknown = UUID()
        try container.update(id: unknown) { $0.error = "Unused" }

        #expect(try container.row(id: note.id)?.status == .rejected("Record too large"))
        #expect(try container.row(id: unknown) == nil)
    }

    @Test func anUnknownIdHasNoRow() throws {
        #expect(try RecordContainer().row(id: UUID()) == nil)
    }

    @Test func aFileContainerKeepsItsRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let note = Note(title: "Kept")
        try RecordContainer(url: url).save(our: note, zone: "Notes")
        #expect(try RecordContainer(url: url).row(id: note.id)?.ours?["title"] == "Kept")
    }
}
