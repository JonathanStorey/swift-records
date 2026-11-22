import Foundation
import Testing
@testable import SwiftRecords
import Versioning
#if canImport(CoreLocation)
import CoreLocation
#endif

private struct Place: Codable, Hashable {
    var home: Location?
    var route: [Location] = []
}

@Suite struct LocationTests {
    private let chicago = Location(latitude: 41.88, longitude: -87.63, altitude: 181, horizontalAccuracy: 5, verticalAccuracy: 3, course: 90, courseAccuracy: 2, speed: 1.5, speedAccuracy: 0.5, timestamp: Date(timeIntervalSince1970: 1_000_000))

    @Test func defaultsMatchCoreLocation() {
        let location = Location(latitude: 1, longitude: 2)
        #expect(location.altitude == 0)
        #expect(location.horizontalAccuracy == 0)
        #expect([location.verticalAccuracy, location.course, location.courseAccuracy, location.speed, location.speedAccuracy] == [-1, -1, -1, -1, -1])
    }

    @Test func worksAsAnOptionalAndInAList() throws {
        #expect(try JSONEncoder().encode(Place()) == Data(#"{"route":[]}"#.utf8))
        let place = Place(home: nil, route: [chicago, chicago])
        #expect(try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(place)) == place)
    }

    @Test func encodesEveryValue() throws {
        let json = try JSONRepresentation(Place(home: chicago))
        #expect(json["home"]?["latitude"] == 41.88)
        #expect(json["home"]?["speedAccuracy"] == 0.5)
        #expect(json["home"]?["timestamp"] != nil)
    }

    @Test func roundTrips() throws {
        let place = Place(home: chicago)
        #expect(try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(place)) == place)
        #expect(try JSONRepresentation(place).decode(Place.self) == place)
    }

    #if canImport(CoreLocation)
    @Test func projectsACLLocation() {
        let location = chicago.clLocation
        #expect(location.coordinate.latitude == 41.88)
        #expect(location.coordinate.longitude == -87.63)
        #expect(location.altitude == 181)
        #expect(location.course == 90)
        #expect(location.speed == 1.5)
        #expect(location.timestamp == chicago.timestamp)
    }

    @Test func roundTripsThroughCLLocation() {
        #expect(Location(chicago.clLocation) == chicago)
    }
    #endif
}
