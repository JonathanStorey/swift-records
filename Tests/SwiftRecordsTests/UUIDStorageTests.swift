import Foundation
@testable import SwiftRecords
import Testing

@Suite struct UUIDStorageTests {
    @Test func storesUUIDsAsSixteenBytes() throws {
        let id = UUID()
        guard case .blob(let bytes) = try ValueCoding.encode(id) else {
            Issue.record("Expected a blob")
            return
        }
        #expect(bytes.count == 16)
        #expect(try ValueCoding.decode(UUID.self, from: .blob(bytes)) == id)
    }

    @Test func readsUUIDsStoredAsText() throws {
        let id = UUID()
        #expect(try ValueCoding.decode(UUID.self, from: .text(id.uuidString)) == id)
    }

    @Test func rejectsBlobsOfTheWrongSize() {
        #expect(throws: DecodingError.self) { try ValueCoding.decode(UUID.self, from: .blob(Data([1, 2, 3]))) }
    }
}
