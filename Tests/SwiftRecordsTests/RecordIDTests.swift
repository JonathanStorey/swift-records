import Foundation
import Testing
@testable import SwiftRecords

private struct Folder: Codable, Identifiable {
    var id = UUID()
}

private struct Shelf: Codable, Identifiable {
    var id: Int
}

private struct Page: Codable {
    var slug: String
}

/// A ``RecordID`` names a record exactly as the container saves it.
@Suite struct RecordIDTests {
    @Test func aUUIDIdIsTheNameAsItIs() throws {
        let folder = Folder()
        let id = try RecordID(folder, zone: "Notes")
        #expect(id == RecordID(name: folder.id.uuidString, zone: "Notes"))
    }

    @Test func anotherIdFollowsTheRecordType() throws {
        #expect(try RecordID(Shelf(id: 42), zone: "Books").name == "Shelf:42")
        #expect(try RecordID(Page(slug: "intro"), id: \.slug, zone: "Pages").name == "Page:intro")
        #expect(try RecordID(Page(slug: "café"), id: \.slug, zone: "Pages").name == "Page::Y2Fmw6k")
    }

    @Test func theNameIsTheRowTheContainerSaves() throws {
        let container = RecordContainer()
        let page = Page(slug: "intro")
        try container.save(our: page, id: \.slug, zone: "Pages")
        let id = try RecordID(page, id: \.slug, zone: "Pages")
        #expect(try container.row(id: RecordContainer.RowID(name: id.name, zone: id.zone)) != nil)
    }

    @Test func anIdTooLongForCloudKitThrows() {
        #expect(throws: EncodingError.self) { try RecordID(Page(slug: String(repeating: "a", count: 300)), id: \.slug, zone: "Pages") }
    }
}
