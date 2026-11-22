import Foundation
import Testing
@testable import SwiftRecords
import Versioning

/// Not `Codable`, `Hashable` or `Sendable`, like a cached image.
private final class Cache {}

private struct Note: Codable, Hashable {
    var body: String = ""
    @Transient var cache: Cache? = nil
    @Transient var draft: String? = nil
}

@Suite struct TransientTests {
    @Test func neverEncodes() throws {
        let note = Note(body: "hi", cache: Cache(), draft: "x")
        #expect(String(decoding: try JSONEncoder().encode(note), as: UTF8.self) == #"{"body":"hi"}"#)
        #expect(try JSONRepresentation(note) == ["body": "hi"])
    }

    @Test func decodesAsNil() throws {
        let note = try JSONDecoder().decode(Note.self, from: Data(#"{"body":"hi","draft":"x"}"#.utf8))
        #expect(note.draft == nil)
        #expect(note.cache == nil)
    }

    @Test func isIgnoredByEqualityAndHashing() {
        let note = Note(body: "hi")
        let cached = Note(body: "hi", cache: Cache(), draft: "x")
        #expect(note == cached)
        #expect(note.hashValue == cached.hashValue)
        #expect(note != Note(body: "bye"))
    }
}
