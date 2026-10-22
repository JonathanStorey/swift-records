import Foundation
import SwiftRecords
import Testing

// Two versions of one record type, sharing a table through `@Record(name:)`.

@Record(name: "Dish")
struct DishV1 {
    var id = UUID()
    var title: String
    var minutes: Int
    var shelf: [Ingredient] = []
}

@Record(name: "Dish")
struct DishV2 {
    var id = UUID()
    var title: String
    @Renamed(from: "minutes") var duration: Int = 0
    @Renamed(from: "shelf") var ingredients: [Ingredient] = []
    @Indexed var servings = 2
    var rating: Double = 4.5
    var tags: [String] = ["new"]
    var note: String?
}

@Record
struct Ingredient {
    var id = UUID()
    var name: String
    @Reference(from: \DishV2.ingredients) var dishIDs: Set<DishV2.ID>
}

@Suite struct SchemaEvolutionTests {
    let container = try! RecordContainer(zone: .inMemory)

    @Test func rowsWithoutANewPropertyTakeItsDefault() throws {
        let old = DishV1(title: "Soup", minutes: 20)
        try container.save(old)

        let dish = try #require(try container.fetch(DishV2.self, id: old.id))
        #expect(dish.servings == 2)
        #expect(dish.rating == 4.5)
        #expect(dish.tags == ["new"])
        #expect(dish.note == nil)
    }

    @Test func nullColumnsTakeTheDefaultToo() throws {
        try container.save(DishV2(title: "New"))            // adds the columns
        let old = DishV1(title: "Old", minutes: 5)
        try container.save(old)                              // leaves them NULL for this row
        #expect(try container.fetch(DishV2.self, id: old.id)?.servings == 2)
    }

    @Test func renamedPropertiesKeepTheirValuesAndQueries() throws {
        let old = DishV1(title: "Stew", minutes: 90, shelf: [Ingredient(name: "Beef")])
        try container.save(old)

        let dish = try #require(try container.fetch(DishV2.self, id: old.id))
        #expect(dish.duration == 90)
        #expect(dish.ingredients.map(\.name) == ["Beef"])

        let long = try container.fetch(DishV2.self, where: #Predicate { $0.duration > 60 })
        #expect(long.map(\.id) == [old.id])

        var edited = dish
        edited.ingredients.append(Ingredient(name: "Carrot"))
        try container.save(edited)
        #expect(try container.fetch(DishV2.self, id: old.id)?.ingredients.map(\.name) == ["Beef", "Carrot"])
    }

    @Test func indexedPropertiesStillQuery() throws {
        try container.save([DishV2(title: "A", servings: 1), DishV2(title: "B", servings: 4)])
        #expect(try container.fetch(DishV2.self, where: #Predicate { $0.servings > 2 }).map(\.title) == ["B"])
    }

    @Test func storedNameIsFixed() throws {
        try container.save(DishV1(title: "X", minutes: 1))
        #expect(try container.changes().first?.recordType == "Dish")
    }
}
