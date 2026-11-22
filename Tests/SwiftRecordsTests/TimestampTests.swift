import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Note: Codable, Hashable {
    var title: String
    @Timestamp var updatedOnServer: Date? = nil
}

@Suite struct TimestampTests {
    private let date = Date(timeIntervalSince1970: 1_000_000)

    @Test func holdsTheDate() {
        #expect(Note(title: "A", updatedOnServer: date).updatedOnServer == date)
        #expect(Note(title: "A").updatedOnServer == nil)
    }

    @Test func isNeverEncoded() throws {
        let data = try JSONEncoder().encode(Note(title: "A", updatedOnServer: date))
        #expect(String(decoding: data, as: UTF8.self) == #"{"title":"A"}"#)
        #expect(try JSONRepresentation(Note(title: "A", updatedOnServer: date)) == ["title": "A"])
    }

    @Test func isDecodedWhenPresent() throws {
        let text = #"{"title":"A","updatedOnServer":1000000}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(Note.self, from: Data(text.utf8)).updatedOnServer == date)
        #expect(try JSONDecoder().decode(Note.self, from: Data(#"{"title":"A"}"#.utf8)).updatedOnServer == nil)
        #expect(try JSONDecoder().decode(Note.self, from: Data(#"{"title":"A","updatedOnServer":null}"#.utf8)).updatedOnServer == nil)
    }

    @Test func isIgnoredByEqualityAndHashing() {
        let saved = Note(title: "A", updatedOnServer: date)
        let local = Note(title: "A")
        #expect(saved == local)
        #expect(saved.hashValue == local.hashValue)
        #expect(Set([saved, local]).count == 1)
        #expect(saved != Note(title: "B", updatedOnServer: date))
    }
}
