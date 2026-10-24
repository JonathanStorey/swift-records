import Foundation
@testable import SwiftRecords
import Testing

@Record
struct Dish {
    var id = UUID()
    var name: String
    var servings: Int
    var rating: Double?
    var served: Date?
}

@MainActor
@Suite struct SortTests {
    let container = try! RecordContainer(for: [Dish.self], inMemory: true)

    /// Ties, nils and repeated names, so every comparison has a case to get wrong.
    func stock() throws -> [Dish] {
        let dishes = (0..<40).map { index in
            Dish(
                name: ["Soup", "salad", "Éclair", "Bread", "apple pie"][index % 5],
                servings: index % 4,
                rating: index % 3 == 0 ? nil : Double(index % 7) / 2,
                served: index % 5 == 0 ? nil : Date(timeIntervalSince1970: Double(index % 6) * 3_600)
            )
        }
        try container.save(dishes)
        return dishes
    }

    @Test func numbersAndDatesSortInSQL() {
        let sql = RecordOrder([SortDescriptor(\Dish.servings, order: .reverse), SortDescriptor(\Dish.served), SortDescriptor(\Dish.rating)])
        #expect(sql.columns?.map(\.column) == ["servings", "served", "rating"])
        #expect(sql.columns?.map(\.descending) == [true, false, false])
        #expect(RecordOrder([SortDescriptor(\Dish.servings), SortDescriptor(\Dish.name)]).columns == nil)
    }

    @Test func fetchesSortAsSwiftDoes() throws {
        let dishes = try stock()
        let sorts: [[SortDescriptor<Dish>]] = [
            [],
            [SortDescriptor(\.servings, order: .reverse)],
            [SortDescriptor(\.rating)],
            [SortDescriptor(\.rating, order: .reverse)],
            [SortDescriptor(\.served, order: .reverse), SortDescriptor(\.servings)],
            [SortDescriptor(\.name)],
            [SortDescriptor(\.servings), SortDescriptor(\.name, order: .reverse)],
        ]
        for sort in sorts {
            let expected = RecordOrder(sort).sorted(dishes).map(\.id)
            let context = container.mainContext
            #expect(try context.fetch(RecordDescriptor<Dish>(sortBy: sort)).map(\.id) == expected)
            #expect(try context.fetchIdentifiers(RecordDescriptor<Dish>(sortBy: sort)) == expected)
            let filter = #Predicate<Dish> { $0.servings > 0 }
            let filtered = RecordOrder(sort).sorted(dishes.filter { $0.servings > 0 }).map(\.id)
            #expect(try context.fetch(RecordDescriptor<Dish>(predicate: filter, sortBy: sort)).map(\.id) == filtered)
        }
    }

    @Test func pagesFollowTheSort() throws {
        let dishes = try stock()
        for sort in [[SortDescriptor(\Dish.rating, order: .reverse)], [SortDescriptor(\Dish.name)]] {
            let expected = RecordOrder(sort).sorted(dishes).map(\.id)
            let page = RecordDescriptor<Dish>(sortBy: sort, fetchLimit: 7, fetchOffset: 10)
            #expect(try container.mainContext.fetch(page).map(\.id) == Array(expected[10..<17]))
            #expect(try container.mainContext.fetchIdentifiers(page) == Array(expected[10..<17]))
            #expect(try container.mainContext.fetchCount(page) == 7)
        }
    }

    @Test func backgroundFetchesSortToo() async throws {
        let dishes = try stock()
        let expected = RecordOrder([SortDescriptor(\Dish.servings)]).sorted(dishes).map(\.id)
        let ids = try await container.performBackgroundTask { context in
            try context.fetch(RecordDescriptor<Dish>(sortBy: [SortDescriptor(\.servings)])).map(\.id)
        }
        #expect(ids == expected)
    }

    @Test func unsavedEditsTakeTheirSortedPlace() throws {
        let context = container.mainContext
        context.autosaveEnabled = false
        let order = RecordOrder([SortDescriptor(\Dish.servings)])
        let small = Dish(name: "Small", servings: 1)
        var large = Dish(name: "Large", servings: 8)
        try container.save([small, large])
        let fetched = try context.fetch(RecordDescriptor<Dish>(sortBy: order.descriptors))

        context.insert(Dish(name: "Middle", servings: 4))
        large.servings = 0
        context.insert(large)
        #expect(context.overlay(fetched, in: .default, order: order) { _ in true }.map(\.name) == ["Large", "Small", "Middle"])
    }
}
