import Foundation
import SwiftRecords
import Testing

@Suite struct ZoneTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zones-\(UUID())")

    @Test func zoneNameIsTheFileName() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecordContainer(zone: "drafts", directory: directory)
        try store.save(ToDo(title: "Draft"))

        #expect(store.url == directory.appendingPathComponent("drafts.sqlite"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("drafts.sqlite").path))
    }

    @Test func zonesAreSeparateFiles() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try RecordContainer(zone: .default, directory: directory).save(ToDo(title: "Main"))
        try RecordContainer(zone: "archive", directory: directory).save(ToDo(title: "Old"))

        #expect(try RecordContainer(zone: .default, directory: directory).fetch(ToDo.self).map(\.title) == ["Main"])
        #expect(try RecordContainer(zone: "archive", directory: directory).fetch(ToDo.self).map(\.title) == ["Old"])
    }

    @Test func inMemoryWritesNothing() throws {
        let store = try RecordContainer(zone: .inMemory, directory: directory)
        try store.save(ToDo(title: "Gone"))
        #expect(store.url == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: ["", ".hidden", "a/b", "a\\b", "a:b"])
    func rejectsUnsafeNames(_ name: String) {
        #expect(throws: RecordContainerError.invalidZoneName(name)) {
            try RecordContainer(zone: Zone(name), directory: directory)
        }
    }

    @Test func defaultDirectoryIsApplicationSupport() {
        let path = Zone.defaultDirectory.path
        #expect(path.hasSuffix("/Records"))
        #if os(iOS)
        #expect(path.contains("/Library/Application Support/"))
        #endif
    }

    #if canImport(Darwin)
    @Test func directoryIsIncludedInBackup() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var marked = directory
        try marked.setResourceValues(excluded)

        _ = try RecordContainer(zone: "local", directory: directory)
        let reread = URL(fileURLWithPath: directory.path, isDirectory: true)
        let values = try reread.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == false)
    }
    #endif
}
