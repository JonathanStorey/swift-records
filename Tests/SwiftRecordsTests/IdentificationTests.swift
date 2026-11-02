import Foundation
import Identification
import Testing
@_spi(SyncProvider) @testable import SwiftRecords

/// IDs SwiftRecords makes with swift-identification, which must never change, and the order it relies on.
@Suite struct IdentificationTests {
    /// A link's ID is hashed from its relation and ends, so it has to stay the same in every release, or
    /// devices on different versions would make two links for one pair.
    @Test func linkIDsAreStable() throws {
        let from = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let to = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        #expect(_RecordLink.id(relation: "Recipe.tags", from: from, to: to).uuidString == "E3B15D23-DC64-5A7E-A27C-BA9C19DC9022")
    }

    /// Records list by ID, comparing their stored bytes, so timestamp IDs made later must sort later.
    @Test func timestampIDsSortInCreationOrder() {
        let ids = (0..<1_000).map { _ in UUID.timestamp }
        #expect(ids == ids.sorted { $0.precedes($1) })
    }
}
