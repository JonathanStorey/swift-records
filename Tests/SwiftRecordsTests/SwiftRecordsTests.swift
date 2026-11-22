import Testing
@testable import SwiftRecords
import Versioning

@Suite struct SwiftRecordsTests {
    @Test func versioningIsAvailable() throws {
        #expect(try JSONRepresentation("records") == "records")
    }
}
