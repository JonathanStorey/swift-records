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

        #expect(try container.url() == directory.appendingPathComponent("_default.sqlite"))
        #expect(try container.url(for: "drafts") == directory.appendingPathComponent("drafts.sqlite"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("drafts.sqlite").path))
        #expect(try context.fetch(ToDo.self).map(\.title) == ["Draft"])
        context.zone = nil
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
        context.zone = nil
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

    @Test(arguments: ["", ".hidden", "_default", "a/b", "a\\b", "a:b"])
    func rejectsUnsafeNames(_ name: String) throws {
        let context = try RecordContainer(inMemory: true).mainContext
        context.zone = name
        #expect(throws: RecordsError.invalidZoneName(name)) {
            try context.fetch(ToDo.self)
        }
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
