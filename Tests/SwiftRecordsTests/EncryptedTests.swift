import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Note: Codable, Hashable {
    @Encrypted var body: String = ""
    @Encrypted var pin: Int? = nil
    @Encrypted var created: Date = Date(timeIntervalSinceReferenceDate: 0)
    @Encrypted var secret: Data = Data([1, 2, 3])
}

@Suite struct EncryptedTests {
    private func json(_ value: some Encodable, encoder: JSONEncoder = JSONEncoder()) throws -> String {
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func encodesLikeItsValue() throws {
        let note = Note(body: "hi", pin: 42)
        #expect(try json(note) == #"{"body":"hi","created":0,"pin":42,"secret":"AQID"}"#)
        #expect(try JSONRepresentation(note)["secret"] == "AQID")
    }

    @Test func keepsEncoderStrategies() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(try json(Note(), encoder: encoder).contains(#""created":"2001-01-01T00:00:00Z""#))
    }

    @Test func leavesOutNilAndDecodesMissingAsNil() throws {
        #expect(try !json(Note()).contains("pin"))
        let text = #"{"body":"hi","created":0,"secret":"AQID"}"#
        let note = try JSONDecoder().decode(Note.self, from: Data(text.utf8))
        #expect(note.pin == nil)
        #expect(note.body == "hi")
    }

    @Test func roundTrips() throws {
        let note = Note(body: "hi", pin: 7)
        #expect(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note)) == note)
        #expect(try JSONRepresentation(note).decode(Note.self) == note)
    }
}
