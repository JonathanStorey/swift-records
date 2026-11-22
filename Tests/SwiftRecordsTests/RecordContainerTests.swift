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
