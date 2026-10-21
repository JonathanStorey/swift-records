import Foundation
import SwiftRecords
import Testing

/// A record whose own Codable groups properties into nested containers.
@Record
struct Place {
    var id = UUID()
    var name: String
    var street: String
    var city: String
    var tags: [String]

    enum CodingKeys: String, CodingKey { case id, name, address, tags }
    enum AddressKeys: String, CodingKey { case street, city }

    init(name: String, street: String, city: String, tags: [String]) {
        self.name = name
        self.street = street
        self.city = city
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let address = try container.nestedContainer(keyedBy: AddressKeys.self, forKey: .address)
        street = try address.decode(String.self, forKey: .street)
        city = try address.decode(String.self, forKey: .city)
        var list = try container.nestedUnkeyedContainer(forKey: .tags)
        tags = []
        while !list.isAtEnd { tags.append(try list.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        var address = container.nestedContainer(keyedBy: AddressKeys.self, forKey: .address)
        try address.encode(street, forKey: .street)
        try address.encode(city, forKey: .city)
        var list = container.nestedUnkeyedContainer(forKey: .tags)
        for tag in tags { try list.encode(tag) }
    }
}

@Suite struct CustomCodingTests {
    let container = try! RecordContainer(zone: .inMemory)

    @Test func nestedContainersRoundTripAsJSONColumns() throws {
        let place = Place(name: "Cafe", street: "1 Main St", city: "Springfield", tags: ["coffee", "wifi"])
        try container.save(place)

        let fetched = try #require(try container.fetch(Place.self, id: place.id))
        #expect(fetched.street == "1 Main St")
        #expect(fetched.city == "Springfield")
        #expect(fetched.tags == ["coffee", "wifi"])
    }
}

@MainActor
@Suite struct SharedContextTests {
    @Test func sharedReturnsTheLatestContextForAFile() throws {
        let mine = try RecordsContext(zone: .inMemory)
        #expect(try RecordsContext.shared(.inMemory) === mine)

        let newer = try RecordsContext(zone: .inMemory)
        #expect(try RecordsContext.shared(.inMemory) === newer)
    }
}
