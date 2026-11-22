import Foundation
import Testing
@testable import SwiftRecords
import Versioning

@Suite struct RecordContainerTests {
    @Test func theDefaultContainerIsInMemory() throws {
        let container = RecordContainer()
        #expect(container.url == nil)
        try container.execute("CREATE TABLE note (title TEXT)")
    }

    @Test func eachInMemoryContainerIsItsOwnDatabase() throws {
        try RecordContainer().execute("CREATE TABLE note (title TEXT)")
        try RecordContainer().execute("CREATE TABLE note (title TEXT)")
    }

    @Test func aFileContainerKeepsItsDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let container = try RecordContainer(url: url)
            #expect(container.url == url)
            try container.execute("CREATE TABLE note (title TEXT)")
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(throws: DatabaseError.self, "The reopened file already has the table.") {
            try RecordContainer(url: url).execute("CREATE TABLE note (title TEXT)")
        }
    }

    @Test func aFolderThatDoesNotExistCannotOpen() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("records.sqlite")
        #expect(throws: DatabaseError.self) { try RecordContainer(url: url) }
    }

    @Test func badSQLThrowsSQLitesMessage() {
        do {
            try RecordContainer().execute("CREAT TABLE note (title TEXT)")
            Issue.record("Expected a syntax error.")
        } catch {
            #expect(error.description.contains("syntax error"))
        }
    }
}

private struct Tag: Codable, Mergeable {
    var name = ""
}

private struct Memo: Codable, Mergeable {
    var text = ""
}

@Suite struct RecordContainerInitTests {
    private static let types = ["Tag", "Memo"]

    @Test func registersAnArrayOfTypes() throws {
        let container = try RecordContainer(for: [Tag.self, Memo.self], storage: .inMemory)
        #expect(container.url == nil)
        for name in Self.types { #expect(throws: Never.self) { try container.registeredType(named: name) } }
    }

    @Test func registersVariadicTypes() throws {
        let container = try RecordContainer(for: Tag.self, Memo.self, storage: .inMemory)
        for name in Self.types { #expect(throws: Never.self) { try container.registeredType(named: name) } }
    }

    @Test func storesTheDatabaseInApplicationSupport() throws {
        let url = try RecordContainer.storeURL(appGroup: nil)
        #expect(url.lastPathComponent == "default.records")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Application Support"
            || url.deletingLastPathComponent().path.hasSuffix(".local/share"))
    }

    #if !canImport(Darwin)
    @Test func anAppGroupNeedsAnApplePlatform() {
        #expect(throws: DatabaseError.self) { try RecordContainer(for: Tag.self, storage: .appGroup("group.example")) }
    }
    #endif
}
