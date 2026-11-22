import Foundation
import Testing
@testable import SwiftRecords
import Versioning

@Suite struct ZoneTests {
    @Test func aNamedZoneIsYourOwnPrivateZone() {
        let notes: Zone = "Notes"
        #expect(notes == Zone("Notes"))
        #expect(notes.owner == "__defaultOwner__")
        #expect(notes.database == .private)
    }

    @Test func someoneElsesZoneIsShared() {
        #expect(Zone("Notes", owner: "_8a2f").database == .shared)
        #expect(Zone("Notes", owner: "_8a2f") != Zone("Notes"))
    }

    @Test func theDefaultZoneIsPublic() {
        #expect(Zone.public.database == .public)
        #expect(Zone("_defaultZone") == .public)
    }

    @Test func roundTripsThroughCodable() throws {
        let zone = Zone("Notes", owner: "_8a2f")
        #expect(try JSONDecoder().decode(Zone.self, from: JSONEncoder().encode(zone)) == zone)
        #expect(try JSONRepresentation(zone) == ["name": "Notes", "owner": "_8a2f"])
    }
}
