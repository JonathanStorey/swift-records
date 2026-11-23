import Foundation
import Testing
@testable import SwiftRecords
import Versioning

@Suite struct RelationshipTests {
    private let note = "00000000-0000-0000-0000-00000000000A"
    private let tag = "00000000-0000-0000-0000-00000000000B"

    private var relationship: Relationship {
        Relationship(between: ("Note.tags", note), and: ("Tag.notes", tag))
    }

    @Test func sortsItsSidesByProperty() {
        let reversed = Relationship(between: ("Tag.notes", tag), and: ("Note.tags", note))
        #expect(relationship == reversed, "Either end builds the same relationship.")
        #expect(relationship.keyPaths == ["Note.tags", "Tag.notes"])
        #expect(relationship.references == [note, tag])
        #expect(relationship.orders == [nil, nil])
    }

    @Test func aSymmetricRelationshipSortsItsSidesByRecord() {
        let friends = Relationship(between: ("Person.friends", tag), and: ("Person.friends", note))
        #expect(friends == Relationship(between: ("Person.friends", note), and: ("Person.friends", tag)))
        #expect(friends.references == [note, tag])
    }

    @Test func theIDReadsAsBothPropertiesAndAHash() {
        let hash = UUID(stableHashOf: "Note.tags|Tag.notes|\(note)|\(tag)").uuidString
        #expect(relationship.id == "Note.tags~Tag.notes:" + hash)
    }

    @Test func theIDIsItsRecordName() throws {
        #expect(try RecordContainer.recordName(for: relationship.id, type: "Relationship") == relationship.id)
    }

    @Test func eachPartChangesTheID() {
        #expect(Relationship(between: ("Note.labels", note), and: ("Tag.notes", tag)).id != relationship.id)
        #expect(Relationship(between: ("Note.tags", note), and: ("Tag.notes", UUID().uuidString)).id != relationship.id)
    }

    @Test func orderIsNotPartOfTheID() {
        var placed = relationship
        placed[orderIn: note, keyPath: "Note.tags"] = 3
        #expect(placed.id == relationship.id)
        #expect(placed != relationship)
    }

    @Test func placesEachSideByItsRecordAndProperty() {
        var placed = Relationship(between: ("Tag.notes", tag), and: ("Note.tags", note))
        placed[orderIn: note, keyPath: "Note.tags"] = 1
        placed[orderIn: tag, keyPath: "Tag.notes"] = 7
        placed[orderIn: tag, keyPath: "Note.tags"] = 9
        #expect(placed.orders == [1, 7], "A side the relationship lacks is ignored.")
        #expect(placed[orderIn: tag, keyPath: "Tag.notes"] == 7)
        #expect(placed[orderIn: tag, keyPath: "Note.tags"] == nil)
    }

    @Test func aRecordRelatedToItselfKeepsBothSidesApart() {
        var links = Relationship(between: ("Note.links", note), and: ("Note.backlinks", note))
        links[orderIn: note, keyPath: "Note.links"] = 2
        #expect(links.keyPaths == ["Note.backlinks", "Note.links"])
        #expect(links.orders == [nil, 2])
        #expect(links.target(from: note, keyPath: "Note.links") == note)
    }

    @Test func targetIsTheOtherSide() {
        #expect(relationship.target(from: note, keyPath: "Note.tags") == tag)
        #expect(relationship.target(from: tag, keyPath: "Tag.notes") == note)
    }

    @Test func eachSidesOrderMergesOnItsOwn() throws {
        var ours = relationship, theirs = relationship
        ours[orderIn: note, keyPath: "Note.tags"] = 1
        theirs[orderIn: tag, keyPath: "Tag.notes"] = 2
        #expect(try ours.merging(with: theirs, from: relationship).orders == [1, 2])
        #expect(try theirs.merging(with: ours, from: relationship).orders == [1, 2])
    }

    @Test func bothDevicesMovingOneSideKeepsOurs() throws {
        var ours = relationship, theirs = relationship
        ours[orderIn: note, keyPath: "Note.tags"] = 1
        theirs[orderIn: note, keyPath: "Note.tags"] = 5
        #expect(try ours.merging(with: theirs, from: relationship).orders == [1, nil])
        #expect(throws: MergeConflict()) { try ours.merging(with: theirs) }
    }

    @Test func encodesLikeAModel() throws {
        var placed = relationship
        placed[orderIn: note, keyPath: "Note.tags"] = 2
        let json = try JSONRepresentation(placed)
        #expect(json["id"] == nil)
        #expect(json["keyPaths"] == ["Note.tags", "Tag.notes"])
        #expect(json["references"] == [
            ["recordName": .string(note), "action": "none"],
            ["recordName": .string(tag), "action": "none"],
        ])
        #expect(json["orders"] == [2, nil])
    }

    @Test func roundTrips() throws {
        #expect(try JSONDecoder().decode(Relationship.self, from: JSONEncoder().encode(relationship)) == relationship)
        #expect(try JSONRepresentation(relationship).decode(Relationship.self) == relationship)
    }
}
