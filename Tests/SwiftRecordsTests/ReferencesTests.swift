import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Tag: Codable, Identifiable {
    var id: UUID
    var notes: [RecordID<Note>] = []
}

private struct Note: Codable, Hashable {
    @References(to: \Tag.notes) var tags: [RecordID<Tag>] = []

    /// The wrapper's storage is private, so only this file can read it.
    var tagsStorage: References<Tag>.Storage? { _tags.storage }
}

private struct Attachment: Codable, Identifiable {
    var id: UUID
}

private struct Folder: Codable, Hashable {
    @References var attachments: [RecordID<Attachment>] = []

    var attachmentsStorage: References<Attachment>.Storage? { _attachments.storage }
}

private struct Post: Codable, Identifiable {
    var id: UUID
    @References(to: \Label.posts) var labels: [RecordID<Label>] = []
}

private struct Label: Codable, Hashable, Identifiable {
    var id = UUID()
    @References(from: \Post.labels) var posts: [RecordID<Post>] = []

    var postsStorage: References<Post>.Storage? { _posts.storage }
    var postsInverse: String? { get throws { try _posts.inverse } }
}

/// Stores `labels` under another coding key.
private struct Article: Codable, Identifiable {
    var id: UUID
    @References(to: \Sticker.articles) var labels: [RecordID<Sticker>] = []

    enum CodingKeys: String, CodingKey {
        case id
        case labels = "stickers"
    }
}

private struct Sticker: Codable, Identifiable {
    var id = UUID()
    @References(from: \Article.labels) var articles: [RecordID<Article>] = []

    var articlesInverse: String? { get throws { try _articles.inverse } }
}

private struct Match: Codable, Hashable {
    @References(action: .deleteSelf) var tags: [RecordID<Tag>] = []

    var tagsAction: RecordReference.Action { _tags.action }
}

@Suite struct ReferencesTests {
    private let note = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

    /// The id of a record named `name` in the zone `"Z"`.
    private func id<T>(_ name: UUID) -> RecordID<T> {
        RecordID(name: name, zone: "Z")
    }

    private func link(_ keyPath: String, from source: UUID, to target: UUID, order: Int? = nil, inverseOrder: Int? = nil) -> Relationship {
        var link = Relationship(keyPath: keyPath, from: source, to: target)
        link.order = order
        link.inverseOrder = inverseOrder
        return link
    }

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func holdsTheIDsInOrder() {
        #expect(Note(tags: [id(b), id(a)]).tags == [id(b), id(a)])
        #expect(Note().tags == [])
    }

    @Test func encodesEachReferenceWithTheAction() throws {
        #expect(try json(Note(tags: [id(a)])) == #"{"tags":[{"action":"none","owner":"__defaultOwner__","recordName":"00000000-0000-0000-0000-0000000000A1","zone":"Z"}]}"#)
        #expect(try json(Match(tags: [id(a)])) == #"{"tags":[{"action":"deleteSelf","owner":"__defaultOwner__","recordName":"00000000-0000-0000-0000-0000000000A1","zone":"Z"}]}"#)
    }

    @Test func keepsTheAction() throws {
        let model = Match(tags: [id(a), id(b)])
        let decoded = try JSONDecoder().decode(Match.self, from: JSONEncoder().encode(model))
        #expect(decoded == model)
        #expect(decoded.tagsAction == .deleteSelf)
        #expect(try JSONDecoder().decode(Match.self, from: Data("{}".utf8)).tagsAction == .none)
    }

    @Test func initializerPicksTheStorage() {
        #expect(Folder().attachmentsStorage == .field)
        #expect(Note().tagsStorage == .links)
        #expect(Label().postsStorage == .inverse)
    }

    @Test func inverseNamesTheDeclaringCodingKey() throws {
        #expect(try Label().postsInverse == "Post.labels")
        #expect(try Sticker().articlesInverse == "Article.stickers")
    }

    @Test func decodedListHasNoStorageAndStillEqualsTheOriginal() throws {
        let model = Note(tags: [id(a), id(b)])
        let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(model))
        #expect(decoded.tagsStorage == nil)
        #expect(decoded == model)
        #expect(try JSONDecoder().decode(Note.self, from: Data("{}".utf8)).tagsStorage == nil)
    }

    @Test func fieldAndLinksEncodeAlike() throws {
        #expect(try json(Folder(attachments: [id(a)])) == #"{"attachments":[{"action":"none","owner":"__defaultOwner__","recordName":"00000000-0000-0000-0000-0000000000A1","zone":"Z"}]}"#)
    }

    @Test func inverseSortsByInverseOrder() {
        let links = [
            link("Post.labels", from: a, to: note, order: 0, inverseOrder: 2),
            link("Post.labels", from: b, to: note, order: 5, inverseOrder: 1),
        ]
        #expect(References<Post>(links, from: id(note) as RecordID<Label>).wrappedValue == [id(b), id(a)])
    }

    @Test func readsAnyRecordName() throws {
        let note = try JSONDecoder().decode(Note.self, from: Data(#"{"tags":[{"recordName":"Tag:swift","zone":"Z","action":"none"}]}"#.utf8))
        #expect(note.tags == [RecordID(name: "Tag:swift", zone: "Z")])
    }

    @Test func rejectsAReferenceWithNoZone() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Note.self, from: Data(#"{"tags":[{"recordName":"00000000-0000-0000-0000-0000000000A1","action":"none"}]}"#.utf8)) }
    }

    @Test func leavesOutAnEmptyList() throws {
        #expect(try json(Note()) == "{}")
        #expect(try JSONDecoder().decode(Note.self, from: Data("{}".utf8)).tags == [])
    }

    @Test func roundTrips() throws {
        let model = Note(tags: [id(a), id(b)])
        #expect(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(model)) == model)
        #expect(try JSONRepresentation(model).decode(Note.self) == model)
    }

    @Test func fetchedLinksSortByOrderWithUnplacedLinksLast() {
        let links = [
            link("Note.tags", from: note, to: a, order: 4),
            link("Note.tags", from: note, to: c, inverseOrder: 0),
            link("Note.tags", from: note, to: b, order: 0),
        ]
        let model = References<Tag>(links, from: id(note) as RecordID<Note>, action: .deleteSelf)
        #expect(model.wrappedValue == [id(b), id(a), id(c)])
        #expect(model.action == .deleteSelf)
    }
}
