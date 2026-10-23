import Foundation
@testable import SwiftRecords
import Testing

@MainActor
@Suite struct ZoneTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zones-\(UUID())")

    @Test func zonesAreFilesInTheFolder() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try RecordContainer(directory: directory)
        let context = container.mainContext
        context.save(ToDo(title: "Main"))
        context.zone = "drafts"
        context.save(ToDo(title: "Draft"))
        try context.save()

        #expect(container.url() == directory.appendingPathComponent("_default.sqlite"))
        #expect(container.url(for: "drafts") == directory.appendingPathComponent("drafts.sqlite"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("drafts.sqlite").path))
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Draft"])
        context.zone = .default
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Main"])
    }

    @Test func pendingChangesStayInTheirZone() throws {
        let context = try RecordContainer(inMemory: true).mainContext
        context.autosaveEnabled = false
        context.save(ToDo(title: "Main"))
        context.zone = "archive"
        context.save(ToDo(title: "Old"))
        #expect(context.pendingChangeCount == 2)

        #expect(try context.fetch(ToDo.self).map(\.title) == ["Old"])
        context.zone = .default
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Main"])
    }

    @Test func switchingZonesRefreshesViews() throws {
        let context = try RecordContainer(inMemory: true).mainContext
        let before = context.changeCount
        context.zone = "other"
        #expect(context.changeCount == before + 1)
        context.zone = "other"
        #expect(context.changeCount == before + 1)
    }

    @Test func eachZoneKeepsItsOwnData() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try RecordContainer(directory: directory)
        try await container.performBackgroundTask(in: "archive") { try $0.save(ToDo(title: "Old")) }
        #expect(try container.fetch(ToDo.self).isEmpty)

        let reopened = try RecordContainer(directory: directory).mainContext
        reopened.zone = "archive"
        #expect(try await reopened.fetch(ToDo.self).map(\.title) == ["Old"])

        try container.deleteAllData(in: "archive")
        #expect(try await reopened.fetch(ToDo.self).isEmpty)
    }

    @Test func inMemoryWritesNothing() throws {
        let container = try RecordContainer(directory: directory, inMemory: true)
        try container.save(ToDo(title: "Gone"))
        #expect(container.url == nil)
        #expect(container.isStoredInMemoryOnly)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: ["", ".hidden", "_default", "_memory", "a/b", "a\\b", "a:b", "my drafts", "1st", "-a", String(repeating: "a", count: 65)])
    func rejectsUnsafeNames(_ name: String) {
        #expect(throws: RecordsError.invalidZoneName(name)) {
            try Zone(name)
        }
    }

    @Test func namesAreLowercased() throws {
        let drafts = try Zone("Drafts")
        let mixed = try Zone("my_drafts-2")
        #expect(drafts == "drafts")
        #expect(Zone(stringLiteral: "Pantry").name == "pantry")
        #expect(mixed.name == "my_drafts-2")
    }

    @Test func zonesRoundTripThroughJSON() throws {
        let zones: [Zone] = ["drafts", .default, .inMemory, .localOnly]
        let data = try JSONEncoder().encode(zones)
        #expect(String(decoding: data, as: UTF8.self) == #"["drafts","_default","_memory","_local"]"#)
        #expect(try JSONDecoder().decode([Zone].self, from: data) == zones)
        #expect(throws: RecordsError.invalidZoneName("a/b")) {
            try JSONDecoder().decode(Zone.self, from: Data(#""a/b""#.utf8))
        }
    }

    @Test func inMemoryZoneWritesNoFile() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try RecordContainer(directory: directory)
        try await container.performBackgroundTask(in: .inMemory) { try $0.save(ToDo(title: "Scratch")) }
        #expect(container.url(for: .inMemory) == nil)
        #expect(try await container.performBackgroundTask(in: .inMemory) { try $0.fetch(ToDo.self) }.map(\.title) == ["Scratch"])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!files.contains { $0.hasPrefix("_memory") })
    }

    @Test func reservedZonesNeverAskForAProvider() throws {
        let asked = AskedZones()
        let container = try RecordContainer(inMemory: true, syncProvider: { zone in
            asked.append(zone)
            return nil
        })
        let context = container.mainContext
        for zone: Zone in [.inMemory, .localOnly, "drafts"] {
            context.zone = zone
            _ = try context.fetch(ToDo.self)
        }
        #expect(asked.zones == [.default, "drafts"])
    }

    private final class AskedZones: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Zone] = []
        var zones: [Zone] { lock.withLock { list } }
        func append(_ zone: Zone) { lock.withLock { list.append(zone) } }
    }

    @Test func defaultDirectoryIsApplicationSupport() {
        let path = RecordContainer.defaultDirectory.path
        #expect(path.hasSuffix("/Records"))
        #if os(iOS)
        #expect(path.contains("/Library/Application Support/"))
        #endif
    }

    #if canImport(Darwin)
    @Test func directoryIsIncludedInBackup() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Mark the folder the way earlier versions did, by writing the attribute behind
        // `isExcludedFromBackup` directly. Setting it through URL resource values can land late and
        // race the container clearing it.
        let value = Array("com.apple.backupd".utf8)
        #expect(setxattr(directory.path, excludeAttribute, value, value.count, 0, 0) == 0)

        _ = try RecordContainer(directory: directory)
        #expect(getxattr(directory.path, excludeAttribute, nil, 0, 0, 0) < 0)
    }

    private let excludeAttribute = "com.apple.metadata:com_apple_backup_excludeItem"
    #endif
}
