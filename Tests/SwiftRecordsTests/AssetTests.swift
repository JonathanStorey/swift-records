import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Note: Codable, Hashable {
    @Asset var attachment: Data? = nil
}

@Suite struct AssetTests {
    private let bytes = Data("hello".utf8)

    private func file(containing data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    @Test func settingDataWritesAFile() throws {
        var note = Note()
        note.attachment = bytes
        let url = try #require(note.$attachment)
        #expect(url.isFileURL)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(note.attachment == bytes)
    }

    @Test func memberwiseInitWritesAFile() throws {
        let note = Note(attachment: bytes)
        #expect(note.$attachment != nil)
        #expect(note.attachment == bytes)
    }

    @Test func settingTheURLReadsThatFile() throws {
        let url = try file(containing: bytes)
        var note = Note()
        note.$attachment = url
        #expect(note.$attachment == url)
        #expect(note.attachment == bytes)
    }

    @Test func readsTheFileWhenAccessed() throws {
        let url = try file(containing: bytes)
        var note = Note()
        note.$attachment = url
        try Data("changed".utf8).write(to: url)
        #expect(note.attachment == Data("changed".utf8))
    }

    @Test func missingFileReadsAsNil() {
        var note = Note()
        note.$attachment = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(note.attachment == nil)
    }

    @Test func settingNilClearsTheURL() {
        var note = Note(attachment: bytes)
        note.attachment = nil
        #expect(note.$attachment == nil)
    }

    @Test func encodesTheURL() throws {
        let url = try file(containing: bytes)
        var note = Note()
        note.$attachment = url
        #expect(try JSONRepresentation(note) == ["attachment": .string(url.absoluteString)])
        let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        #expect(decoded == note)
        #expect(decoded.attachment == bytes)
    }

    @Test func leavesOutNil() throws {
        #expect(try JSONRepresentation(Note()) == [:])
        for text in ["{}", #"{"attachment":null}"#] {
            #expect(try JSONDecoder().decode(Note.self, from: Data(text.utf8)).$attachment == nil)
        }
    }
}
