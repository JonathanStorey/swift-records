import Foundation
import Testing
@testable import SwiftRecords

private struct Unencodable: Codable, Identifiable {
    var id = "broken"

    func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(id, .init(codingPath: [], debugDescription: "Never encodes."))
    }
}

/// The container throws ``RecordError`` cases that name what went wrong.
@Suite struct RecordErrorTests {
    @Test func anUnregisteredTypeIsNamed() {
        #expect(throws: RecordError.notRegistered(type: "Missing")) { try RecordContainer().registeredType(named: "Missing") }
    }

    @Test func aRecordsOwnEncodingFailureIsUnencodable() throws {
        let container = RecordContainer()
        // `#require(throws:)` returns the error only from Swift 6.1, and CI also runs 6.0.
        var thrown: RecordError?
        do throws(RecordError) { try container.save(our: Unencodable(), zone: "Records") } catch { thrown = error }
        let error = try #require(thrown)
        guard case .unencodable(let type, _) = error else {
            Issue.record("Expected unencodable, got \(error)")
            return
        }
        #expect(type == "Unencodable")
    }

    @Test func everyCaseHasAMessage() {
        let errors: [RecordError] = [
            .notRegistered(type: "Note"), .nameTooLong(name: "Note:x"),
            .referenceOutsideZone(reference: "Folder:a", zone: "Other"), .missingInverse(property: "Note.tags"),
            .mismatchedInverse(property: "Note.tags", inverse: "Tag.notes", pairedWith: "Folder.notes"),
            .unencodable(type: "Note", description: "NaN"), .database(DatabaseError(code: 13, description: "disk full")),
        ]
        for error in errors {
            #expect(error.localizedDescription == error.description)
            #expect(!error.description.isEmpty)
        }
        #expect(RecordError.mismatchedInverse(property: "Note.tags", inverse: "Tag.notes", pairedWith: "Folder.notes").description.contains("Folder.notes"))
    }

    @Test func anyErrorBecomesARecordError() {
        #expect(RecordError(RecordError.nameTooLong(name: "n"), type: "Note") == .nameTooLong(name: "n"))
        #expect(RecordError(DatabaseError(code: 13, description: "full"), type: "Note") == .database(DatabaseError(code: 13, description: "full")))
        // Described as the existential, as the initializer sees it, since macOS prints a
        // CocoaError differently when it is held as `any Error`.
        let other: any Error = CocoaError(.fileNoSuchFile)
        #expect(RecordError(other, type: "Note") == .unencodable(type: "Note", description: "\(other)"))
    }
}
