import Foundation
import Testing
@testable import SwiftRecords
import Versioning

// Scenarios that run on every platform: nested values through save and merge, assets,
// account changes, files that move, concurrency, and a damaged database.

private enum Priority: String, Codable {
    case low, high
}

private enum Shape: Codable, Equatable {
    case circle(radius: Double)
    case square(side: Double)
}

private struct Address: Codable, Equatable {
    var street: String
    var city: String
}

private struct Step: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var isDone = false
}

/// A record with a little of everything a record can hold as JSON.
private struct Project: Codable, Equatable, Identifiable, Mergeable {
    var id: UUID
    var title = "Base"
    var subtitle: String? = "Subtitle"
    var priority = Priority.low
    var address = Address(street: "1 Main", city: "Springfield")
    var steps = [Step(id: 1, name: "Plan")]
    var tags: Set<String> = ["a"]
    var scores: [String: Int] = ["x": 1]
    var shape = Shape.circle(radius: 1)
    var created = Date(timeIntervalSinceReferenceDate: 1_000.25)
    var grid: [[Int]] = [[1, 2], [3]]
    var large = Int64.max
    var ratio = 0.1
    var emoji = "Café 👩🏽‍💻"
    @Encrypted var secret = "pin"
    @Encrypted var code: Int? = 7
}

private struct Photo: Codable, Identifiable, Mergeable {
    var id: UUID
    var caption = ""
    @Asset var picture: Data? = nil
}

/// A record whose keys differ from its property names.
private struct Renamed: Codable, Identifiable, Mergeable {
    var id: UUID
    @Asset var photo: Data? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case photo = "photo_file"
    }
}

private extension RecordContainer {
    /// A container holding `project` as the server's version, synced.
    static func synced(_ project: Project) throws -> RecordContainer {
        let container = RecordContainer()
        container.register(Project.self)
        try container.receive(project)
        return container
    }

    /// Saves `project` as the server's newest version.
    func receive(_ project: Project) throws {
        try save(their: JSONRepresentation(project), id: project.id, zone: "Projects", type: "Project", metadata: Data([1]))
    }

    /// The row's `ours`, read as a `Project`.
    func ourProject(id: UUID) throws -> Project? {
        try row(id: id)?.ours?.decode(Project.self)
    }

    /// The bytes of the file the row's `ours` points at for `field`.
    func ourBytes(id: UUID, field: String) throws -> Data? {
        guard case .string(let text)? = try row(id: id)?.ours?[field], let url = URL(string: text) else { return nil }
        return try? Data(contentsOf: url)
    }
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

@Suite struct RecordContainerNestedValueTests {
    private let id = UUID()

    @Test func aNestedRecordReadsBackUnchanged() throws {
        let container = RecordContainer()
        let project = Project(id: id)
        try container.save(our: project, zone: "Projects")
        #expect(try container.ourProject(id: id) == project)
    }

    @Test func aFileContainerReadsBackUnchanged() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("records.sqlite")
        let project = Project(id: id, large: Int64.min, ratio: 1e-300)
        try RecordContainer(url: url).save(our: project, zone: "Projects")
        #expect(try RecordContainer(url: url).ourProject(id: id) == project, "Numbers keep their precision through the table.")
    }

    @Test func changesToDifferentNestedFieldsBothSurvive() throws {
        let container = try RecordContainer.synced(Project(id: id))
        var ours = Project(id: id)
        ours.address.city = "Shelbyville"
        ours.steps.append(Step(id: 2, name: "Build"))
        ours.grid = [[9]]
        try container.save(our: ours, zone: "Projects")

        var theirs = Project(id: id)
        theirs.title = "Renamed"
        theirs.steps[0].isDone = true
        theirs.scores["y"] = 2
        theirs.shape = .square(side: 3)
        theirs.secret = "new pin"
        try container.receive(theirs)

        var expected = theirs
        expected.address.city = "Shelbyville"
        expected.steps.append(Step(id: 2, name: "Build"))
        expected.grid = [[9]]
        #expect(try container.ourProject(id: id) == expected)
        #expect(try container.row(id: id)?.status == .waitingToUpload)
    }

    @Test func anOptionalClearedOnOneSideStaysCleared() throws {
        let container = try RecordContainer.synced(Project(id: id))
        var ours = Project(id: id)
        ours.subtitle = nil
        ours.code = nil
        try container.save(our: ours, zone: "Projects")
        try container.receive(Project(id: id, title: "Theirs"))

        let merged = try #require(try container.ourProject(id: id))
        #expect(merged.title == "Theirs")
        #expect(merged.subtitle == nil)
        #expect(merged.code == nil, "An encrypted optional clears the same way.")
    }

    @Test func anOptionalClearedOnTheServerStaysCleared() throws {
        let container = try RecordContainer.synced(Project(id: id))
        try container.save(our: Project(id: id, title: "Ours"), zone: "Projects")
        try container.receive(Project(id: id, subtitle: nil))

        let merged = try #require(try container.ourProject(id: id))
        #expect(merged.title == "Ours")
        #expect(merged.subtitle == nil)
    }

    @Test func bothSidesChangingOneNestedValueKeepOursByDefault() throws {
        let container = try RecordContainer.synced(Project(id: id))
        var ours = Project(id: id)
        ours.address.city = "Ours"
        ours.shape = .circle(radius: 2)
        try container.save(our: ours, zone: "Projects")
        var theirs = Project(id: id)
        theirs.address.city = "Theirs"
        theirs.shape = .square(side: 2)
        theirs.priority = .high
        try container.receive(theirs)

        let merged = try #require(try container.ourProject(id: id))
        #expect(merged.address.city == "Ours")
        #expect(merged.shape == .circle(radius: 2))
        #expect(merged.priority == .high)
    }

    @Test func favoringTheirsKeepsTheServersNestedValue() throws {
        let container = try RecordContainer.synced(Project(id: id))
        container.favoring = .theirs
        var ours = Project(id: id)
        ours.address.city = "Ours"
        ours.title = "Ours"
        try container.save(our: ours, zone: "Projects")
        var theirs = Project(id: id)
        theirs.address.city = "Theirs"
        try container.receive(theirs)

        let merged = try #require(try container.ourProject(id: id))
        #expect(merged.address.city == "Theirs")
        #expect(merged.title == "Ours")
    }

    @Test func aMergeThatMatchesTheServerLeavesNothingToUpload() throws {
        let container = try RecordContainer.synced(Project(id: id))
        try container.save(our: Project(id: id, title: "Same"), zone: "Projects")
        try container.receive(Project(id: id, title: "Same"))
        #expect(try container.row(id: id)?.status == .synced)
    }

    @Test func anOlderShapeFromTheServerKeepsOurNewerFields() throws {
        let container = try RecordContainer.synced(Project(id: id))
        try container.save(our: Project(id: id, priority: .high), zone: "Projects")
        // Written by a version of the app before `priority` and `shape` existed.
        guard case .object(var pairs) = try JSONRepresentation(Project(id: id, title: "Older")) else { return }
        pairs.removeAll { $0.key == "priority" || $0.key == "shape" }
        try container.save(their: .object(pairs), id: id, zone: "Projects", type: "Project", metadata: Data([2]))

        let merged = try #require(try container.ourProject(id: id))
        #expect(merged.title == "Older")
        #expect(merged.priority == .high)
    }

    @Test func aFieldTheTypeDoesNotHaveIsDroppedByAMerge() throws {
        let container = try RecordContainer.synced(Project(id: id))
        try container.save(our: Project(id: id, title: "Ours"), zone: "Projects")
        guard case .object(var pairs) = try JSONRepresentation(Project(id: id)) else { return }
        pairs.append((key: "retired", value: true))
        try container.save(their: .object(pairs), id: id, zone: "Projects", type: "Project", metadata: Data([2]))
        #expect(try container.row(id: id)?.ours?["retired"] == nil)
    }

    @Test func aVersionOfTheWrongShapeKeepsOurs() throws {
        let container = try RecordContainer.synced(Project(id: id))
        try container.save(our: Project(id: id, title: "Ours"), zone: "Projects")
        try container.save(their: ["id": .string(id.uuidString), "title": ["not": "a string"]], id: id, zone: "Projects", type: "Project", metadata: Data([2]))
        let row = try #require(try container.row(id: id))
        #expect(try row.ours?.decode(Project.self).title == "Ours")
        #expect(row.status == .waitingToUpload)
    }
}

@Suite struct RecordContainerLifecycleTests {
    private let id = UUID()

    @Test func anAccountChangeRemovesEverything() throws {
        let container = RecordContainer()
        try container.save(our: Project(id: id), zone: "Projects")
        try container.save(our: Photo(id: UUID(), picture: Data([1])), zone: Zone("Shared", owner: "someone"))
        container.engineStateData = Data([1])

        try container.clear()
        #expect(try container.zones().isEmpty)
        #expect(try container.pendingRows().isEmpty)
        #expect(container.engineStateData == nil)
        #expect(!FileManager.default.fileExists(atPath: container.assets.path))

        try container.save(our: Project(id: id), zone: "Projects")
        #expect(try container.row(id: id) != nil, "The container works again after it is cleared.")
    }

    @Test func anEmptyEngineStateIsKeptAsEmpty() {
        let container = RecordContainer()
        container.engineStateData = Data()
        #expect(container.engineStateData == Data())
    }

    @Test func pendingWorkOutlivesARelaunch() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("records.sqlite")
        let deleted = Project(id: UUID())
        do {
            let container = try RecordContainer(url: url)
            try container.save(our: Project(id: id), zone: "Projects")
            try container.save(their: JSONRepresentation(deleted), id: deleted.id, zone: "Projects", type: "Project", metadata: Data([1]))
            try container.delete(id: deleted.id)
            container.engineStateData = Data([7])
        }

        let container = try RecordContainer(url: url)
        let pending = try container.pendingRows()
        #expect(Set(pending.map { $0.id }) == [id, deleted.id])
        #expect(pending.first { $0.id == deleted.id }?.isDeleted == true)
        #expect(container.engineStateData == Data([7]))
    }

    @Test func assetsAreFoundAfterTheContainerMoves() throws {
        let original = temporaryFolder(), moved = temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: moved)
        }
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try RecordContainer(url: original.appendingPathComponent("records.sqlite")).save(our: Photo(id: id, picture: Data([4, 2])), zone: "Photos")

        // As iOS can move an app's container when the app updates.
        try FileManager.default.moveItem(at: original, to: moved)
        let container = try RecordContainer(url: moved.appendingPathComponent("records.sqlite"))
        #expect(try container.ourBytes(id: id, field: "picture") == Data([4, 2]))
        guard case .string(let text)? = try container.row(id: id)?.ours?["picture"] else {
            Issue.record("Expected a picture")
            return
        }
        #expect(text.hasPrefix(container.assetFolder(id: id).absoluteString))
    }

    @Test func resendingAZoneKeepsItsAssets() throws {
        let container = RecordContainer()
        container.register(Photo.self)
        try container.save(our: Photo(id: id, picture: Data([5])), zone: "Photos")
        try container.update(id: id) { row in
            row.metadata = Data([1])
            row.confirm(row.ours!)
        }

        try container.clear(in: "Photos", resending: true)
        #expect(try container.ourBytes(id: id, field: "picture") == Data([5]))
        #expect(try container.row(id: id)?.status == .waitingToUpload)
    }

    @Test func anAssetUnderACustomKeyIsCopiedIn() throws {
        let container = RecordContainer()
        try container.save(our: Renamed(id: id, photo: Data([9])), zone: "Photos")
        #expect(try container.ourBytes(id: id, field: "photo_file") == Data([9]))
        guard case .string(let text)? = try container.row(id: id)?.ours?["photo_file"] else {
            Issue.record("Expected a photo")
            return
        }
        #expect(text.hasPrefix(container.assetFolder(id: id).absoluteString))
    }

    @Test func aRolledBackTransactionKeepsTheFilesItsRowsUse() throws {
        let container = RecordContainer()
        container.register(Photo.self)
        try container.save(our: Photo(id: id, picture: Data([6])), zone: "Photos")
        try container.update(id: id) { row in
            row.metadata = Data([1])
            row.confirm(row.ours!)
        }

        #expect(throws: DatabaseError.self) {
            try container.transaction { () throws(DatabaseError) in
                try container.update(id: id) { row in row.base = ["id": .string(id.uuidString), "caption": ""] }
                throw DatabaseError(code: 1, description: "Stopped")
            }
        }
        guard case .string(let text)? = try container.row(id: id)?.base?["picture"], let url = URL(string: text) else {
            Issue.record("Expected a picture")
            return
        }
        #expect(try Data(contentsOf: url) == Data([6]))
    }

    @Test func deletingANewRecordRemovesItsFiles() throws {
        let container = RecordContainer()
        try container.save(our: Photo(id: id, picture: Data([1])), zone: "Photos")
        try container.delete(id: id)
        #expect(!FileManager.default.fileExists(atPath: container.assetFolder(id: id).path))
    }

    @Test func replacingAnAssetKeepsOnlyTheFilesInUse() throws {
        let container = RecordContainer()
        var photo = Photo(id: id, picture: Data([1]))
        for byte in UInt8(2)...5 {
            photo.picture = Data([byte])
            try container.save(our: photo, zone: "Photos")
        }
        let files = try FileManager.default.contentsOfDirectory(at: container.assetFolder(id: id), includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(try container.ourBytes(id: id, field: "picture") == Data([5]))
    }

    @Test func savingAgainAfterADeleteUndoesIt() throws {
        let container = try RecordContainer.synced(Project(id: id))
        try container.delete(id: id)
        #expect(try container.row(id: id)?.isDeleted == true)
        try container.save(our: Project(id: id, title: "Back"), zone: "Projects")

        let row = try #require(try container.row(id: id))
        #expect(!row.isDeleted)
        #expect(try row.ours?.decode(Project.self).title == "Back")
    }
}

@Suite struct RecordContainerRobustnessTests {
    @Test func manyThreadsCanSaveAndReadAtOnce() throws {
        let container = RecordContainer()
        container.register(Project.self)
        let ids = (0..<20).map { _ in UUID() }
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            let id = ids[(index / 4) % ids.count]
            switch index % 4 {
            case 0: try? container.save(our: Project(id: id, title: "Ours \(index)"), zone: "Projects")
            case 1: try? container.receive(Project(id: id, title: "Theirs \(index)"))
            case 2: _ = try? container.row(id: id)
            default: _ = try? container.pendingRows()
            }
        }
        for id in ids {
            #expect(try container.row(id: id) != nil)
        }
    }

    @Test func aDamagedColumnThrowsADatabaseError() throws {
        let id = UUID()
        let container = RecordContainer()
        try container.save(our: Project(id: id), zone: "Projects")
        try container.execute("UPDATE record SET ours = 'not json'")

        #expect(throws: DatabaseError.self) { try container.row(id: id) }
        #expect(throws: DatabaseError.self) { try container.receive(Project(id: id)) }
        // A damaged row can still be removed.
        try container.clear(in: "Projects")
        #expect(try container.row(id: id) == nil)
    }

    @Test func aFailedTransactionWritesNothing() throws {
        let id = UUID()
        let container = RecordContainer()
        container.register(Project.self)
        let json = try JSONRepresentation(Project(id: id))
        #expect(throws: DatabaseError.self) {
            try container.transaction { () throws(DatabaseError) in
                try container.save(their: json, id: id, zone: "Projects", type: "Project", metadata: Data([1]))
                throw DatabaseError(code: 1, description: "Stopped on purpose")
            }
        }
        #expect(try container.row(id: id) == nil)
    }

    @Test func aContainerFileThatCannotOpenThrows() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/records.sqlite")
        #expect(throws: DatabaseError.self) { try RecordContainer(url: url) }
    }

    @Test func idsWithAnyTextHashTheSameEverywhere() throws {
        let first = try RecordContainer.recordID(for: "Café 👩🏽‍💻", type: "Page")
        let second = try RecordContainer.recordID(for: "Café 👩🏽‍💻", type: "Page")
        #expect(first == second)
        #expect(try RecordContainer.recordID(for: "Cafe", type: "Page") != first)
    }
}
