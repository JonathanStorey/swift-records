import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title: String
}

private extension RecordContainer {
    func save(their note: Note) throws {
        try save(their: JSONRepresentation(note), id: note.id, zone: "Notes", type: "Note", metadata: Data([1]))
    }
}

@Suite struct RecordContainerBatchTests {
    @Test func aTransactionCommitsTogether() throws {
        let container = RecordContainer()
        let first = Note(title: "First"), second = Note(title: "Second")
        let json = (try JSONRepresentation(first), try JSONRepresentation(second))
        try container.transaction { () throws(DatabaseError) in
            try container.save(their: json.0, id: first.id, zone: "Notes", type: "Note", metadata: nil)
            try container.save(their: json.1, id: second.id, zone: "Notes", type: "Note", metadata: nil)
        }
        #expect(try container.row(id: first.id) != nil)
        #expect(try container.row(id: second.id) != nil)
    }

    @Test func aTransactionThatThrowsWritesNothing() throws {
        let container = RecordContainer()
        let note = Note(title: "Draft")
        let json = try JSONRepresentation(note)
        #expect(throws: DatabaseError.self) {
            try container.transaction { () throws(DatabaseError) in
                try container.save(their: json, id: note.id, zone: "Notes", type: "Note", metadata: nil)
                throw DatabaseError(code: 1, description: "Stopped")
            }
        }
        #expect(try container.row(id: note.id) == nil)
    }

    @Test func pendingRowsAreUnsentSavesAndDeletes() throws {
        let container = RecordContainer()
        let saved = Note(title: "Saved"), synced = Note(title: "Synced"), deleted = Note(title: "Deleted"), rejected = Note(title: "Rejected")
        try container.save(our: saved, zone: "Notes")
        try container.save(their: synced)
        try container.save(their: deleted)
        try container.delete(our: deleted)
        try container.save(our: rejected, zone: "Notes")
        try container.update(id: rejected.id) { $0.error = "Record too large" }

        let pending = try container.pendingRows()
        #expect(pending.count == 2)
        #expect(pending.contains { $0.id == saved.id.uuidString && !$0.isDeleted && $0.zone == "Notes" })
        #expect(pending.contains { $0.id == deleted.id.uuidString && $0.isDeleted })
    }

    @Test func zonesListsEachZoneOnce() throws {
        let container = RecordContainer()
        try container.save(our: Note(title: "A"), zone: "Notes")
        try container.save(our: Note(title: "B"), zone: "Notes")
        try container.save(our: Note(title: "C"), zone: Zone("Notes", owner: "someone"))
        try container.save(our: Note(title: "D"), zone: .public)

        let zones = try container.zones()
        #expect(zones == ["Notes", Zone("Notes", owner: "someone"), .public])
        #expect(zones.filter { $0.database == .private } == ["Notes"])
    }
}
