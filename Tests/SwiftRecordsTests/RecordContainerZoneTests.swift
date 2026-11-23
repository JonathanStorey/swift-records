import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Photo: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title = ""
    @Asset var picture: Data? = nil
}

/// The same record kept in two zones: each copy is its own row, keyed by name and zone.
@Suite struct RecordContainerZoneTests {
    private let photo = Photo(title: "Beach", picture: Data([1, 2, 3]))
    private let notes = Zone("Notes")
    private let shared = Zone("Notes", owner: "_friend")
    private var inNotes: RecordContainer.RowID { RecordContainer.RowID(name: photo.id, zone: notes) }
    private var inShared: RecordContainer.RowID { RecordContainer.RowID(name: photo.id, zone: shared) }

    @Test func theSameRecordInTwoZonesIsTwoRows() throws {
        let container = RecordContainer.inMemory(Photo.self)
        try container.save(our: photo, zone: notes)
        try container.save(our: photo, zone: shared)

        let mine = try #require(try container.row(id: inNotes))
        let theirs = try #require(try container.row(id: inShared))
        #expect(mine.zone == notes)
        #expect(theirs.zone == shared, "A zone with the same name and another owner is another zone.")
        #expect(mine.ours?["title"] == "Beach")
        #expect(theirs.ours?["title"] == "Beach")
        #expect(try container.pendingRows().count == 2)
    }

    @Test func aChangeInOneZoneLeavesTheOther() throws {
        let container = RecordContainer.inMemory(Photo.self)
        try container.save(our: photo, zone: notes)
        try container.save(our: photo, zone: shared)
        var changed = photo
        changed.title = "Lake"
        try container.save(our: changed, zone: notes)
        try container.save(their: ["id": .string(photo.id.uuidString), "title": "Server"], id: photo.id, zone: shared, type: "Photo", metadata: Data([7]))

        let mine = try #require(try container.row(id: inNotes))
        let theirs = try #require(try container.row(id: inShared))
        #expect(mine.ours?["title"] == "Lake")
        #expect(mine.base == nil, "The server's version in the other zone is not this row's.")
        #expect(theirs.ours?["title"] == "Beach")
        #expect(theirs.metadata == Data([7]))
    }

    @Test func aDeleteInOneZoneLeavesTheOther() throws {
        let container = RecordContainer.inMemory(Photo.self)
        try container.save(our: photo, zone: notes)
        try container.save(our: photo, zone: shared)
        try container.delete(our: photo, zone: notes)

        #expect(try container.row(id: inNotes) == nil)
        #expect(try container.row(id: inShared)?.ours?["title"] == "Beach")
    }

    @Test func clearingOneZoneLeavesTheOther() throws {
        let container = RecordContainer.inMemory(Photo.self)
        try container.save(our: photo, zone: notes)
        try container.save(our: photo, zone: shared)
        try container.clear(in: shared)

        #expect(try container.row(id: inNotes) != nil)
        #expect(try container.row(id: inShared) == nil)
    }

    @Test func eachZoneKeepsItsOwnAssetFiles() throws {
        let container = RecordContainer.inMemory(Photo.self)
        try container.save(our: photo, zone: notes)
        try container.save(our: photo, zone: shared)
        let mine = container.assetFolder(id: inNotes)
        let theirs = container.assetFolder(id: inShared)
        #expect(mine != theirs)
        #expect(try FileManager.default.contentsOfDirectory(atPath: mine.path).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: theirs.path).count == 1)

        try container.delete(our: photo, zone: notes)
        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: theirs.path).count == 1, "The other copy keeps its file.")
        let picture = try #require(try container.row(id: inShared)?.ours?["picture"])
        guard case .string(let text) = picture else { Issue.record("The picture is not a file."); return }
        #expect(text.hasPrefix(theirs.absoluteString))
    }
}
