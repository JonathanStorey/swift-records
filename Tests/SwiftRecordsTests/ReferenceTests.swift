import Foundation
import Testing
@testable import SwiftRecords
import Versioning

/// Identified by a `String`, so its record name is its type and its id.
private struct Folder: Codable, Identifiable {
    var id: String
}

/// Identified by an `Int`.
private struct Shelf: Codable, Identifiable {
    var id: Int
}

private struct Note: Codable, Hashable, Identifiable {
    var id: UUID
    @Reference<Folder> var folder: Folder.ID? = nil
}

private struct Child: Codable, Hashable {
    @Reference<Folder>(action: .deleteSelf) var folder: Folder.ID? = nil
    @Reference<Note> var note: Note.ID? = nil
    @Reference<Shelf> var shelf: Shelf.ID? = nil
}

@Suite struct ReferenceTests {
    private let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    @Test func holdsTheTargetsOwnID() {
        let note = Note(id: noteID, folder: "inbox")
        #expect(note.folder == "inbox")
        #expect(note.$folder.zone == nil, "A reference built in code is placed when its record is saved.")
        #expect(Note(id: noteID).folder == nil)
    }

    @Test func encodesARecordReferenceNamedLikeTheTarget() throws {
        #expect(try json(Note(id: noteID, folder: "inbox")) == #"{"folder":{"action":"none","recordName":"Folder:inbox"},"id":"00000000-0000-0000-0000-000000000001"}"#)
    }

    @Test func namesEachKindOfIDAsTheContainerDoes() throws {
        let child = Child(folder: "café", note: noteID, shelf: 42)
        let encoded = try JSONRepresentation(child)
        #expect(encoded["folder"]?["recordName"] == "Folder::Y2Fmw6k")
        #expect(encoded["note"]?["recordName"] == "00000000-0000-0000-0000-000000000001")
        #expect(encoded["shelf"]?["recordName"] == "Shelf:42")
        #expect(try encoded.decode(Child.self) == child)
    }

    @Test func leavesOutNil() throws {
        #expect(try json(Note(id: noteID)) == #"{"id":"00000000-0000-0000-0000-000000000001"}"#)
        #expect(try JSONRepresentation(Note(id: noteID)) == ["id": "00000000-0000-0000-0000-000000000001"])
    }

    @Test func decodesMissingAndNullAsNil() throws {
        for text in [#"{"id":"00000000-0000-0000-0000-000000000001"}"#, #"{"id":"00000000-0000-0000-0000-000000000001","folder":null}"#] {
            #expect(try decode(Note.self, text).folder == nil)
        }
    }

    @Test func roundTrips() throws {
        let note = Note(id: noteID, folder: "inbox")
        #expect(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note)) == note)
        #expect(try JSONRepresentation(note).decode(Note.self) == note)
    }

    @Test func readsTheIDAndZoneBack() throws {
        let note = try decode(Note.self, #"{"id":"00000000-0000-0000-0000-000000000001","folder":{"recordName":"Folder:inbox","zone":"Z","owner":"_8a2f","action":"none"}}"#)
        #expect(note.folder == "inbox")
        #expect(note.$folder.zone == Zone("Z", owner: "_8a2f"))
        #expect(try decode(Note.self, json(note)) == note, "The zone is encoded.")
    }

    @Test func theZoneIsPartOfTheReference() throws {
        let placed = try decode(Note.self, #"{"id":"00000000-0000-0000-0000-000000000001","folder":{"recordName":"Folder:inbox","zone":"Z","action":"none"}}"#)
        #expect(placed != Note(id: noteID, folder: "inbox"))
        #expect(placed.folder == Note(id: noteID, folder: "inbox").folder)
    }

    @Test func rejectsANameThatIsNotTheTargetsID() {
        for name in ["E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "inbox"] {
            #expect(throws: DecodingError.self, "A String id's name starts with its type.") {
                try decode(Note.self, #"{"id":"00000000-0000-0000-0000-000000000001","folder":{"recordName":"\#(name)","action":"none"}}"#)
            }
        }
        #expect(throws: DecodingError.self, "CloudKit names are case-sensitive, so a lowercase UUID names another record.") {
            try decode(Child.self, #"{"note":{"recordName":"00000000-0000-0000-0000-00000000000a","action":"none"}}"#)
        }
    }

    @Test func keepsTheAction() throws {
        let child = Child(folder: "inbox")
        #expect(child.$folder.action == .deleteSelf)
        #expect(try json(child) == #"{"folder":{"action":"deleteSelf","recordName":"Folder:inbox"}}"#)
        let decoded = try JSONDecoder().decode(Child.self, from: JSONEncoder().encode(child))
        #expect(decoded == child)
        #expect(decoded.$folder.action == .deleteSelf)
    }

    @Test func aNilReferenceDecodesWithNone() throws {
        #expect(try decode(Child.self, "{}").$folder.action == .none)
    }

    @Test func recordReferenceIsCodable() throws {
        let reference = RecordReference(recordName: "A")
        #expect(reference.action == .none)
        #expect(try json(reference) == #"{"action":"none","recordName":"A"}"#)
        #expect(try JSONDecoder().decode(RecordReference.self, from: Data(json(reference).utf8)) == reference)
    }
}

private struct Page: Codable, Hashable {
    @Reference<Folder>(isParent: true) var folder: Folder.ID? = nil
}

@Suite struct ParentReferenceTests {
    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func encodesAParentReferenceWithNoAction() throws {
        #expect(try json(Page(folder: "inbox")) == #"{"folder":{"action":"none","isParent":true,"recordName":"Folder:inbox"}}"#)
    }

    @Test func leavesOutNilAndDecodesMissingAsNil() throws {
        #expect(try json(Page()) == "{}")
        #expect(try JSONDecoder().decode(Page.self, from: Data("{}".utf8)).folder == nil)
    }

    @Test func theFlagSurvivesDecodingAndMerging() throws {
        let model = Page(folder: "inbox")
        let decoded = try JSONDecoder().decode(Page.self, from: JSONEncoder().encode(model))
        #expect(decoded == model)
        #expect(decoded.$folder.isParent)
        #expect(try JSONRepresentation(model).decode(Page.self).$folder.isParent)
        #expect(try DefaultMergeStrategy<Page>().merge(base: Page(), ours: model, theirs: Page()).$folder.isParent)
    }

    @Test func aParentIsNotAPlainReference() throws {
        #expect(!Child(folder: "inbox").$folder.isParent)
        #expect(RecordReference(parent: "A") != RecordReference(recordName: "A"))
        #expect(try JSONDecoder().decode(RecordReference.self, from: Data(#"{"action":"none","recordName":"A"}"#.utf8)).isParent == false)
    }
}
