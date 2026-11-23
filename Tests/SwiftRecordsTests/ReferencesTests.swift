import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Tag: Codable, Hashable, Identifiable {
    var id = UUID()
    @References<Note>(inverse: \Note.tags) var notes: [Note.ID] = []
}

private struct Note: Codable, Hashable, Identifiable {
    var id = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    @References<Tag>(inverse: \Tag.notes) var tags: [Tag.ID] = []
}

private struct Attachment: Codable, Identifiable {
    var id: UUID
}

private struct Folder: Codable, Hashable {
    @References<Attachment> var attachments: [Attachment.ID] = []
}

/// Stores `labels` under another coding key.
private struct Article: Codable, Identifiable {
    var id = UUID()
    @References<Sticker>(inverse: \Sticker.articles) var labels: [Sticker.ID] = []

    enum CodingKeys: String, CodingKey {
        case id
        case labels = "stickers"
    }
}

private struct Sticker: Codable, Identifiable {
    var id = UUID()
    @References<Article>(inverse: \Article.labels) var articles: [Article.ID] = []
}

/// Identified by an `Int` and a `String`, so each finds its inverse with a marker of its own id type.
private struct Shelf: Codable, Identifiable {
    var id: Int
    @References<Book>(inverse: \Book.shelves) var books: [Book.ID] = []
}

private struct Book: Codable, Identifiable {
    var id: String
    @References<Shelf>(inverse: \Shelf.books) var shelves: [Shelf.ID] = []
}

/// Identified by a struct, which no record name reads back as a marker.
private struct Pair: Codable, Hashable {
    var row = 0, column = 0
}

private struct Cell: Codable, Identifiable {
    var id = Pair()
    @References<Grid>(inverse: \Grid.cells) var grids: [Grid.ID] = []
}

private struct Grid: Codable, Identifiable {
    var id = UUID()
    @References<Cell>(inverse: \Cell.grids) var cells: [Cell.ID] = []
}

private struct Match: Codable, Hashable {
    @References<Tag>(action: .deleteSelf) var tags: [Tag.ID] = []
}

@Suite struct ReferencesTests {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    @Test func holdsTheIDsInOrder() {
        #expect(Note(tags: [b, a]).tags == [b, a])
        #expect(Note().tags == [])
        #expect(Note().$tags.zone == nil)
    }

    @Test func encodesAFieldListAsReferences() throws {
        #expect(try json(Folder(attachments: [a])) == #"{"attachments":[{"action":"none","recordName":"00000000-0000-0000-0000-0000000000A1"}]}"#)
        #expect(try json(Match(tags: [a])) == #"{"tags":[{"action":"deleteSelf","recordName":"00000000-0000-0000-0000-0000000000A1"}]}"#)
    }

    @Test func encodesARelationshipListWithItsInverse() throws {
        #expect(try json(Note(tags: [a])) == #"{"id":"00000000-0000-0000-0000-00000000000A","tags":{"$inverse":"Tag.notes","$relationships":[{"action":"none","recordName":"00000000-0000-0000-0000-0000000000A1"}]}}"#)
        #expect(try JSONRepresentation(Tag(notes: [a]))["notes"]?["$inverse"] == "Note.tags", "Each side names the other.")
    }

    @Test func theOtherSideFollowsItsCodingKey() throws {
        #expect(try JSONRepresentation(Sticker())["articles"]?["$inverse"] == "Article.stickers")
        #expect(try JSONRepresentation(Article())["stickers"]?["$inverse"] == "Sticker.articles")
    }

    @Test func intAndStringIDsFindTheirInverse() throws {
        #expect(try JSONRepresentation(Shelf(id: 1))["books"]?["$inverse"] == "Book.shelves")
        #expect(try JSONRepresentation(Book(id: "swift"))["shelves"]?["$inverse"] == "Shelf.books")
    }

    @Test func aStructIDCannotBeFoundByItsInverse() throws {
        #expect(throws: (any Error).self, "Cell finds Grid.cells with a Pair marker, which no record name reads back as.") {
            try JSONRepresentation(Cell())
        }
        let grid = try JSONRepresentation(Grid())
        #expect(grid["cells"]?["$inverse"] == "Cell.grids", "Grid finds Cell.grids with a UUID marker.")
    }

    @Test func anEmptyFieldListIsLeftOutButAnEmptyRelationshipListIsNot() throws {
        #expect(try json(Folder()) == "{}")
        #expect(try JSONRepresentation(Note())["tags"]?["$relationships"] == [], "The container must see a list emptied, to remove its relationships.")
        #expect(try decode(Note.self, #"{"id":"00000000-0000-0000-0000-00000000000A"}"#).tags == [])
    }

    @Test func storageSurvivesDecoding() throws {
        #expect(try decode(Folder.self, json(Folder(attachments: [a]))).$attachments.storage == .field)
        #expect(try decode(Note.self, json(Note(tags: [a]))).$tags.storage == .relationships)
        #expect(try decode(Tag.self, json(Tag(notes: [a]))).$notes.storage == .relationships)
        #expect(try decode(Folder.self, "{}").$attachments.storage == nil, "A missing key cannot tell.")
    }

    @Test func initializerPicksTheStorage() {
        #expect(Folder().$attachments.storage == .field)
        #expect(Note().$tags.storage == .relationships)
        #expect(Tag().$notes.storage == .relationships)
    }

    @Test func keepsTheAction() throws {
        let model = Match(tags: [a, b])
        let decoded = try decode(Match.self, json(model))
        #expect(decoded == model)
        #expect(decoded.$tags.action == .deleteSelf)
        #expect(try decode(Match.self, "{}").$tags.action == .none)
    }

    @Test func readsTheIDsAndZone() throws {
        let folder = try decode(Folder.self, #"{"attachments":[{"recordName":"00000000-0000-0000-0000-0000000000A1","zone":"Z","action":"none"}]}"#)
        #expect(folder.attachments == [a])
        #expect(folder.$attachments.zone == Zone("Z"))
        #expect(folder != Folder(attachments: [a]), "The zone is part of the list.")
    }

    @Test func rejectsANameThatIsNotTheTargetsID() {
        #expect(throws: DecodingError.self) { try decode(Folder.self, #"{"attachments":[{"recordName":"Attachment:a","action":"none"}]}"#) }
    }

    @Test func roundTrips() throws {
        let model = Note(tags: [a, b])
        #expect(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(model)) == model)
        #expect(try JSONRepresentation(model).decode(Note.self) == model)
        let tag = Tag(notes: [a])
        #expect(try JSONRepresentation(tag).decode(Tag.self) == tag)
    }
}
