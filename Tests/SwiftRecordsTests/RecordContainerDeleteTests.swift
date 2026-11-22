import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title: String
}

private extension RecordContainer {
    /// A container holding `note` as the server's version, synced.
    static func synced(_ note: Note) throws -> RecordContainer {
        let container = RecordContainer()
        try container.save(their: JSONRepresentation(note), id: note.id, zone: "Notes", type: "Note", metadata: Data([1]))
        return container
    }
}

@Suite struct RecordContainerDeleteTests {
    @Test func clearingAZoneRemovesOnlyItsRows() throws {
        let container = RecordContainer()
        let kept = Note(title: "Kept"), shared = Note(title: "Shared"), mine = Note(title: "Mine")
        try container.save(our: kept, zone: "Notes")
        try container.save(our: shared, zone: Zone("Notes", owner: "someone"))
        try container.save(our: mine, zone: "Other")

        try container.clear(in: Zone("Notes", owner: "someone"))
        #expect(try container.row(id: shared.id) == nil)
        #expect(try container.row(id: kept.id) != nil)
        #expect(try container.row(id: mine.id) != nil)

        try container.clear()
        #expect(try container.row(id: kept.id) == nil)
        #expect(try container.row(id: mine.id) == nil)
    }

    @Test func resendingAZoneKeepsEachRecordAsNew() throws {
        let synced = Note(title: "Synced"), edited = Note(title: "Edited"), deleted = Note(title: "Deleted"), elsewhere = Note(title: "Elsewhere")
        let container = try RecordContainer.synced(synced)
        for note in [edited, deleted, elsewhere] {
            try container.save(their: JSONRepresentation(Note(id: note.id, title: "Base")), id: note.id, zone: note.id == elsewhere.id ? "Other" : "Notes", type: "Note", metadata: Data([1]))
        }
        try container.save(our: edited, zone: "Notes")
        try container.delete(id: deleted.id)

        try container.clear(in: "Notes", resending: true)

        #expect(try container.row(id: synced.id) == RecordContainer.Row(id: synced.id, zone: "Notes", type: "Note", ours: JSONRepresentation(synced)))
        #expect(try container.row(id: edited.id) == RecordContainer.Row(id: edited.id, zone: "Notes", type: "Note", ours: JSONRepresentation(edited)))
        #expect(try container.row(id: deleted.id) == nil)
        #expect(try container.row(id: elsewhere.id)?.status == .synced)
        #expect(try container.row(id: synced.id)?.status == .waitingToUpload)
    }

    @Test func theEngineStateIsKeptUntilCleared() throws {
        let container = RecordContainer()
        #expect(container.engineStateData == nil)
        container.engineStateData = Data([1])
        container.engineStateData = Data([2])
        #expect(container.engineStateData == Data([2]))

        try container.clear(in: "Notes")
        #expect(container.engineStateData == Data([2]), "Clearing a zone keeps the engine's state.")
        try container.clear()
        #expect(container.engineStateData == nil)

        container.engineStateData = Data([3])
        container.engineStateData = nil
        #expect(container.engineStateData == nil)
    }

    @Test func aFileContainerKeepsTheEngineState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordContainer(url: url).engineStateData = Data([4])
        #expect(try RecordContainer(url: url).engineStateData == Data([4]))
    }

    @Test func aRecordNeverUploadedIsRemovedAtOnce() throws {
        let container = RecordContainer()
        let note = Note(title: "Draft")
        try container.save(our: note, zone: "Notes")
        try container.delete(id: note.id)
        #expect(try container.row(id: note.id) == nil)
    }

    @Test func aSyncedRecordWaitsToUploadItsDelete() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.save(our: Note(id: note.id, title: "Edited"), zone: "Notes")
        try container.delete(id: note.id)

        let row = try #require(try container.row(id: note.id))
        #expect(row.isDeleted)
        #expect(row.ours == nil)
        #expect(row.status == .waitingToUpload)
    }

    @Test func savingAgainUndoesADelete() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.delete(id: note.id)
        try container.save(our: note, zone: "Notes")
        #expect(try container.row(id: note.id)?.isDeleted == false)
    }

    @Test func aConfirmedDeleteRemovesTheRow() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.delete(id: note.id)
        try container.save(deleted: note.id)
        #expect(try container.row(id: note.id) == nil)
    }

    @Test func aDeleteFromAnotherDeviceRemovesASyncedRow() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.save(deleted: note.id)
        #expect(try container.row(id: note.id) == nil)
    }

    @Test func unsentChangesOutliveADeleteFromAnotherDevice() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        let edited = Note(id: note.id, title: "Edited")
        try container.save(our: edited, zone: "Notes")
        try container.save(deleted: note.id)

        let row = try #require(try container.row(id: note.id))
        let ours = try JSONRepresentation(edited)
        #expect(row == RecordContainer.Row(id: note.id, zone: "Notes", type: "Note", ours: ours))
        #expect(row.status == .waitingToUpload)
    }

    @Test func deletingOurRecordFindsItsRowByItsID() throws {
        let note = Note(title: "Kept")
        let container = try RecordContainer.synced(note)
        try container.delete(our: note)
        #expect(try container.row(id: note.id)?.isDeleted == true)

        try container.save(our: Page(slug: "intro"), id: \.slug, zone: "Notes")
        try container.delete(our: Page(slug: "intro", title: "Changed"), id: \.slug)
        #expect(try container.row(id: RecordContainer.recordID(for: "intro", type: "Page")) == nil)
    }
}

private struct Page: Codable {
    var slug: String
    var title = ""
}
