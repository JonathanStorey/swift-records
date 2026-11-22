import Foundation
import Testing
@testable import SwiftRecords
import Versioning

/// A plain struct, so a reference needs nothing from its target.
private struct Folder: Codable {
    var slug: String
}

private struct Note: Codable, Hashable, Identifiable {
    var id: UUID
    @Reference var folder: RecordID<Folder>? = nil
}

private struct Child: Codable, Hashable {
    @Reference(action: .deleteSelf) var folder: RecordID<Folder>? = nil

    /// The wrapper's storage is private, so only this file can read it.
    var folderAction: RecordReference.Action { _folder.action }
    var folderIsParentForTesting: Bool { _folder.isParent }
}

@Suite struct ReferenceTests {
    private let folderID = RecordID<Folder>(name: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!, zone: "Z")
    private let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func holdsTheID() {
        #expect(Note(id: noteID, folder: folderID).folder == folderID)
        #expect(Note(id: noteID).folder == nil)
    }

    @Test func encodesARecordReference() throws {
        #expect(try json(Note(id: noteID, folder: folderID)) == #"{"folder":{"action":"none","owner":"__defaultOwner__","recordName":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","zone":"Z"},"id":"00000000-0000-0000-0000-000000000001"}"#)
    }

    @Test func leavesOutNil() throws {
        #expect(try json(Note(id: noteID)) == #"{"id":"00000000-0000-0000-0000-000000000001"}"#)
        #expect(try JSONRepresentation(Note(id: noteID)) == ["id": "00000000-0000-0000-0000-000000000001"])
    }

    @Test func decodesMissingAndNullAsNil() throws {
        for text in [#"{"id":"00000000-0000-0000-0000-000000000001"}"#, #"{"id":"00000000-0000-0000-0000-000000000001","folder":null}"#] {
            #expect(try JSONDecoder().decode(Note.self, from: Data(text.utf8)).folder == nil)
        }
    }

    @Test func roundTrips() throws {
        let note = Note(id: noteID, folder: folderID)
        #expect(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note)) == note)
        #expect(try JSONRepresentation(note).decode(Note.self) == note)
    }

    @Test func readsLowercaseRecordNames() throws {
        let text = #"{"id":"00000000-0000-0000-0000-000000000001","folder":{"recordName":"e621e1f8-c36c-495a-93fc-0c247a3e6e5f","zone":"Z","action":"none"}}"#
        #expect(try JSONDecoder().decode(Note.self, from: Data(text.utf8)).folder == folderID)
    }

    @Test func rejectsARecordNameThatIsNotAUUID() {
        let text = #"{"id":"00000000-0000-0000-0000-000000000001","folder":{"recordName":"42","zone":"Z","action":"none"}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Note.self, from: Data(text.utf8)) }
    }

    @Test func keepsTheAction() throws {
        let child = Child(folder: folderID)
        #expect(child.folderAction == .deleteSelf)
        #expect(try json(child) == #"{"folder":{"action":"deleteSelf","owner":"__defaultOwner__","recordName":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","zone":"Z"}}"#)
        let decoded = try JSONDecoder().decode(Child.self, from: JSONEncoder().encode(child))
        #expect(decoded == child)
        #expect(decoded.folderAction == .deleteSelf)
    }

    @Test func pointsAtAnyTargetByItsRecordID() throws {
        let id = try RecordID(Folder(slug: "inbox"), id: \.slug, zone: "Z")
        #expect(id == RecordID(name: UUID(stableHashOf: #"Folder|"inbox""#), zone: "Z"))
        #expect(Note(id: noteID, folder: id).folder?.name == id.name)
    }

    @Test func keepsTheZoneAndOwner() throws {
        let shared = RecordID<Folder>(name: folderID.name, zone: Zone("Shared", owner: "_8a2f"))
        let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(Note(id: noteID, folder: shared)))
        #expect(decoded.folder == shared)
    }

    @Test func rejectsAReferenceWithNoZone() {
        let text = #"{"id":"00000000-0000-0000-0000-000000000001","folder":{"recordName":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","action":"none"}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Note.self, from: Data(text.utf8)) }
    }

    @Test func aNilReferenceDecodesWithNone() throws {
        #expect(try JSONDecoder().decode(Child.self, from: Data("{}".utf8)).folderAction == .none)
    }

    @Test func recordReferenceIsCodable() throws {
        let reference = RecordReference(recordName: "A")
        #expect(reference.action == .none)
        #expect(try json(reference) == #"{"action":"none","recordName":"A"}"#)
        #expect(try JSONDecoder().decode(RecordReference.self, from: Data(json(reference).utf8)) == reference)
    }
}

private struct Page: Codable, Hashable {
    @Reference(isParent: true) var folder: RecordID<Folder>? = nil

    /// The wrapper's storage is private, so only this file can read it.
    var folderIsParent: Bool { _folder.isParent }
}

@Suite struct ParentReferenceTests {
    private let folder = RecordID<Folder>(name: UUID(uuidString: "00000000-0000-0000-0000-00000000000F")!, zone: "Z")

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func encodesAParentReferenceWithNoAction() throws {
        #expect(try json(Page(folder: folder)) == #"{"folder":{"action":"none","isParent":true,"owner":"__defaultOwner__","recordName":"00000000-0000-0000-0000-00000000000F","zone":"Z"}}"#)
    }

    @Test func leavesOutNilAndDecodesMissingAsNil() throws {
        #expect(try json(Page()) == "{}")
        #expect(try JSONDecoder().decode(Page.self, from: Data("{}".utf8)).folder == nil)
    }

    @Test func theFlagSurvivesDecodingAndMerging() throws {
        let model = Page(folder: folder)
        let decoded = try JSONDecoder().decode(Page.self, from: JSONEncoder().encode(model))
        #expect(decoded == model)
        #expect(decoded.folderIsParent)
        #expect(try JSONRepresentation(model).decode(Page.self).folderIsParent)
        #expect(try DefaultMergeStrategy<Page>().merge(base: Page(), ours: model, theirs: Page()).folderIsParent)
    }

    @Test func aParentIsNotAPlainReference() throws {
        #expect(!Child(folder: folder).folderIsParentForTesting)
        #expect(RecordReference(parent: "A") != RecordReference(recordName: "A"))
        #expect(try JSONDecoder().decode(RecordReference.self, from: Data(#"{"action":"none","recordName":"A"}"#.utf8)).isParent == false)
    }

    @Test func rejectsARecordNameThatIsNotAUUID() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Page.self, from: Data(#"{"folder":{"recordName":"42","zone":"Z","action":"none","isParent":true}}"#.utf8)) }
    }
}
