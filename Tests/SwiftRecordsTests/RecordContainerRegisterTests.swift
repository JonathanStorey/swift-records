import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Hits: RawRepresentable, Codable, Equatable, Mergeable {
    var rawValue: Int

    func merging(with theirs: Hits, from base: Hits) throws(MergeConflict) -> Hits {
        try merging(with: theirs, from: base, using: .rawValue(.sum()))
    }
}

private struct Note: Codable, Identifiable, Mergeable {
    var id: UUID
    var title = "Base"
    var body = "Base"
    var hits = Hits(rawValue: 3)
}

/// One record type as three versions of an app see it.
private struct Plain: Codable {
    var title: String
}

private struct WithOptional: Codable {
    var title: String
    var color: String?
}

private struct WithRequired: Codable {
    var title: String
    var color: String
}

private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let metadata = Data([7])

// Encoding a Note cannot fail, and a non-throwing helper keeps comparisons inside #expect.
private func json(_ note: Note) -> JSONRepresentation {
    try! JSONRepresentation(note)
}

private extension RecordContainer {
    static func registered() -> RecordContainer {
        let container = RecordContainer.inMemory(Note.self)
        return container
    }

    func save(their note: Note) throws {
        try save(their: json(note), id: note.id, zone: "Notes", type: "Note", metadata: metadata)
    }
}

@Suite struct RecordContainerRegisterTests {
    @Test func aNewRecordBecomesItsBase() throws {
        let container = RecordContainer.registered()
        try container.save(their: Note(id: id))
        let row = try #require(try container.row(id: id))
        #expect(row == RecordContainer.Row(id: id.uuidString, zone: "Notes", type: "Note", metadata: metadata, base: json(Note(id: id))))
        #expect(row.status == .synced)
    }

    @Test func aNewerVersionReplacesTheBaseWhenNothingIsWaiting() throws {
        let container = RecordContainer.registered()
        try container.save(their: Note(id: id))
        try container.save(their: Note(id: id, title: "Newer"))
        #expect(try container.row(id: id)?.base == json(Note(id: id, title: "Newer")))
    }

    @Test func localChangesMergeByTheTypesOwnMerge() throws {
        let container = RecordContainer.registered()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Ours", hits: Hits(rawValue: 5)), zone: "Notes")
        try container.save(their: Note(id: id, body: "Theirs", hits: Hits(rawValue: 4)))

        let row = try #require(try container.row(id: id))
        #expect(row.ours == json(Note(id: id, title: "Ours", body: "Theirs", hits: Hits(rawValue: 6))), "Hits sums, as Note's own merge does.")
        #expect(row.base == json(Note(id: id, body: "Theirs", hits: Hits(rawValue: 4))))
        #expect(row.status == .waitingToUpload)
    }

    @Test func aChangeTheServerAlreadyHasLeavesNothingToUpload() throws {
        let container = RecordContainer.registered()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Same"), zone: "Notes")
        try container.save(their: Note(id: id, title: "Same"))
        let row = try #require(try container.row(id: id))
        #expect(row.status == .synced, "\(row)")
    }

    @Test func aConflictKeepsOursAtTheConflictingFieldByDefault() throws {
        let container = RecordContainer.registered()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        try container.save(their: Note(id: id, title: "Theirs", body: "Theirs"))

        let row = try #require(try container.row(id: id))
        #expect(row.ours == json(Note(id: id, title: "Ours", body: "Theirs")))
        #expect(row.theirs == nil)
        #expect(row.status == .waitingToUpload)
    }

    @Test func theMergeStrategyCanKeepTheirs() throws {
        let container = RecordContainer.registered()
        container.favoring = .theirs
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Ours", body: "Ours"), zone: "Notes")
        try container.save(their: Note(id: id, title: "Theirs"))

        let row = try #require(try container.row(id: id))
        #expect(row.ours == json(Note(id: id, title: "Theirs", body: "Ours")))
    }

    @Test func theMergeKeepsTheSideGivenOnlyWhereItConflicts() throws {
        let container = RecordContainer.registered()
        let base = json(Note(id: id)), ours = json(Note(id: id, title: "Ours"))
        let theirs = json(Note(id: id, title: "Theirs", body: "Theirs"))
        let rowID = RecordContainer.RowID(name: id.uuidString, zone: "Notes")

        let kept = try container.merged(ours, with: theirs, from: base, as: Note.self, id: rowID, favoring: .ours)
        #expect(kept == json(Note(id: id, title: "Ours", body: "Theirs")), "The other side's body still merges.")
        let taken = try container.merged(ours, with: theirs, from: base, as: Note.self, id: rowID, favoring: .theirs)
        #expect(taken == json(Note(id: id, title: "Theirs", body: "Theirs")))
    }

    @Test func registeringStoresTheTypesSchema() throws {
        let container = RecordContainer.registered()
        let schema = try JSONSchema(for: Note.self)
        #expect(container.storedSchema(named: "Note") == schema)
    }

    @Test func aNewPropertyMustBeOptionalToReadRecordsSavedBeforeIt() throws {
        let saved = try JSONSchema(for: Plain.self)
        #expect(try JSONSchema(for: WithOptional.self).isSuperset(of: saved))
        #expect(try !JSONSchema(for: WithRequired.self).isSuperset(of: saved))
    }

    @Test func aVersionTheTypeCannotReadIsIgnored() throws {
        let container = RecordContainer.registered()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        try container.save(their: ["id": .string(id.uuidString), "title": 3], id: id, zone: "Notes", type: "Note", metadata: metadata)

        let row = try #require(try container.row(id: id))
        #expect(row.ours == json(Note(id: id, title: "Ours")))
        #expect(row.theirs == nil)
        #expect(row.error == nil)
        #expect(row.status == .waitingToUpload)
    }

    @Test func anOlderShapeReadsItsMissingFieldsFromTheOtherVersion() throws {
        let container = RecordContainer.registered()
        try container.save(their: Note(id: id))
        try container.save(our: Note(id: id, body: "Mine"), zone: "Notes")
        let older: JSONRepresentation = ["id": .string(id.uuidString), "title": "Theirs", "hits": 3]
        try container.save(their: older, id: id, zone: "Notes", type: "Note", metadata: metadata)

        #expect(try container.row(id: id)?.ours == json(Note(id: id, title: "Theirs", body: "Mine")))
    }

    @Test func relationshipIsRegisteredByDefault() throws {
        _ = try RecordContainer().registeredType(named: "Relationship")
    }

    @Test func anUnregisteredTypeSavesWithNothingToMerge() throws {
        let container = RecordContainer()
        try container.save(their: json(Note(id: id)), id: id, zone: "Notes", type: "Note", metadata: nil)
        #expect(try container.row(id: id)?.base == json(Note(id: id)))
    }

    @Test func anUnregisteredTypeWaitsWhenItWouldMerge() throws {
        let container = RecordContainer()
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        try container.save(their: json(Note(id: id)), id: id, zone: "Notes", type: "Note", metadata: nil)

        let row = try #require(try container.row(id: id))
        #expect(row.theirs == json(Note(id: id)))
        #expect(row.ours == json(Note(id: id, title: "Ours")))
        #expect(row.error?.contains("not registered") == true)
    }
}

/// One record type as two versions of an app see it, and a type only the newer one has.
private enum V1 {
    struct Note: Codable, Identifiable, Mergeable {
        var id: UUID
        var title = ""
    }
}

private enum V2 {
    struct Note: Codable, Identifiable, Mergeable {
        var id: UUID
        var title = ""
        var color: String?
    }

    struct Tag: Codable, Identifiable, Mergeable {
        var id: UUID
        var name = ""
    }
}

@Suite struct RecordContainerSchemaChangeTests {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".records")

    @Test func theSameSchemaKeepsTheEngineState() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordContainer(for: [V1.Note.self], url: url).engineStateData = Data([1])
        let relaunched = try RecordContainer(for: [V1.Note.self], url: url)
        #expect(relaunched.engineStateData == Data([1]))
    }

    @Test func aChangedSchemaClearsTheEngineState() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordContainer(for: [V1.Note.self], url: url).engineStateData = Data([1])
        let updated = try RecordContainer(for: [V2.Note.self], url: url)
        #expect(updated.engineStateData == nil)
        let schema = try JSONSchema(for: V2.Note.self)
        #expect(updated.storedSchema(named: "Note") == schema)
    }

    @Test func aNewTypeClearsTheEngineState() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordContainer(for: [V1.Note.self], url: url).engineStateData = Data([1])
        let updated = try RecordContainer(for: [V1.Note.self, V2.Tag.self], url: url)
        #expect(updated.engineStateData == nil)
    }

    @Test func aClearedStateKeepsWaitingChanges() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let container = try RecordContainer(for: [V1.Note.self], url: url)
        try container.save(our: V1.Note(id: id, title: "Unsent"), zone: "Notes")
        container.engineStateData = Data([1])
        let updated = try RecordContainer(for: [V2.Note.self], url: url)
        #expect(updated.engineStateData == nil)
        let pending = try updated.pendingRows().map(\.id)
        #expect(pending == [id.uuidString])
    }
}
