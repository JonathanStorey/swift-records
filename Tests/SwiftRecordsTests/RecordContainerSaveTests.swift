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

private func recordID<Record: Encodable, ID: Encodable>(of record: Record, id: KeyPath<Record, ID>) throws -> String {
    try RecordContainer.recordName(for: record[keyPath: id], type: RecordContainer.recordType(of: Record.self))
}

@Suite struct RecordContainerSaveTests {
    @Test func aUUIDIDIsTheRecordName() throws {
        let note = Note(title: "Draft")
        #expect(try recordID(of: note, id: \.id) == note.id.uuidString)
    }

    @Test func anyOtherIDIsItsTypeAndItself() throws {
        let id = try recordID(of: Page(slug: "intro"), id: \.slug)
        #expect(id == "Page:intro")
        #expect(try recordID(of: Page(slug: "intro", title: "Changed"), id: \.slug) == id)
        #expect(try recordID(of: Page(slug: "outro"), id: \.slug) != id)
        #expect(try recordID(of: Chapter(slug: "intro"), id: \.slug) == "Chapter:intro", "A name is unique across types, so the type keeps two ids apart.")
    }

    @Test func aNonStringIDIsItsJSON() throws {
        #expect(try RecordContainer.recordName(for: 42, type: "Invoice") == "Invoice:42")
        #expect(try RecordContainer.recordName(for: true, type: "Flag") == "Flag:true")
    }

    @Test func plainASCIIIsKeptAsItIs() throws {
        #expect(try RecordContainer.recordName(for: "getting-started_2.0", type: "Page") == "Page:getting-started_2.0")
        #expect(try RecordContainer.recordName(for: "", type: "Page") == "Page:")
    }

    @Test func anythingElseIsBase64URLAfterTwoColons() throws {
        #expect(try RecordContainer.recordName(for: "café", type: "Page") == "Page::Y2Fmw6k")
        #expect(try RecordContainer.recordName(for: "a b", type: "Page") == "Page::YSBi")
        #expect(try RecordContainer.recordName(for: "50%", type: "Page") == "Page::NTAl")
        for slug in ["👩🏽‍💻", "a/b?c=d&e", "?>?>", "~"] {
            let name = try RecordContainer.recordName(for: slug, type: "Page")
            let isSafe = name.unicodeScalars.allSatisfy { "A"..."Z" ~= $0 || "a"..."z" ~= $0 || "0"..."9" ~= $0 || "-_.:".unicodeScalars.contains($0) }
            #expect(isSafe, "\(name) holds only letters, digits, -, _, . and :.")
        }
    }

    @Test func aStructuredIDIsItsJSONInBase64URL() throws {
        struct Key: Codable, Equatable { var year: Int }
        let name = try RecordContainer.recordName(for: Key(year: 2026), type: "Report")
        #expect(name.hasPrefix("Report::"))
        #expect(RecordContainer.id(Key.self, fromRecordName: name) == Key(year: 2026))
    }

    @Test func theIDReadsBackFromItsName() throws {
        let uuid = UUID()
        for slug in ["intro", "café", "a b/c:d%e", "👩🏽‍💻", "", "?>?>", "Page::Y2Fmw6k"] {
            #expect(RecordContainer.id(String.self, fromRecordName: try RecordContainer.recordName(for: slug, type: "Page")) == slug)
        }
        #expect(RecordContainer.id(Int.self, fromRecordName: try RecordContainer.recordName(for: 42, type: "Invoice")) == 42)
        #expect(RecordContainer.id(UUID.self, fromRecordName: try RecordContainer.recordName(for: uuid, type: "Note")) == uuid)
        #expect(RecordContainer.id(Int.self, fromRecordName: "Page:intro") == nil, "An id of another type does not decode.")
        #expect(RecordContainer.id(String.self, fromRecordName: "no-colon") == nil)
        #expect(RecordContainer.id(String.self, fromRecordName: "Page::not base64!") == nil)
    }

    @Test func aNameUpToCloudKitsLimitIsKept() throws {
        let slug = String(repeating: "a", count: 255 - "Page:".count)
        #expect(try RecordContainer.recordName(for: slug, type: "Page") == "Page:" + slug)
    }

    @Test func aLongerNameThrows() {
        let slug = String(repeating: "a", count: 256 - "Page:".count)
        #expect(throws: EncodingError.self) { try RecordContainer.recordName(for: slug, type: "Page") }
        let encoded = String(repeating: "é", count: 100)
        #expect(throws: EncodingError.self, "100 é are 200 bytes, so their Base64URL is too long.") { try RecordContainer.recordName(for: encoded, type: "Page") }
    }

    @Test func savingARecordWhoseNameIsTooLongThrowsAndSavesNothing() throws {
        let container = RecordContainer()
        #expect(throws: EncodingError.self) { try container.save(our: Page(slug: String(repeating: "a", count: 300)), id: \.slug, zone: "Notes") }
        #expect(try container.zones().isEmpty)
    }

    @Test func aPlainStructSavesUnderItsID() throws {
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
        #expect(row == RecordContainer.Row(id: note.id.uuidString, zone: "Notes", type: "Note", ours: ["id": .string(note.id.uuidString), "title": "Draft"]))
        #expect(row.status == .waitingToUpload)
    }

    @Test func savingAgainReplacesOursAndKeepsTheRest() throws {
        let container = RecordContainer()
        var note = Note(title: "First")
        try container.save(our: note, zone: "Notes")
        try container.execute("UPDATE record SET base = '{\"title\":\"Base\"}', is_deleted = 1, error = 'Record too large'")

        note.title = "Second"
        try container.save(our: note, zone: "Notes")

        let row = try #require(try container.row(id: note.id))
        #expect(row.ours?["title"] == "Second")
        #expect(row.base == ["title": "Base"])
        #expect(row.zone == "Notes")
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
