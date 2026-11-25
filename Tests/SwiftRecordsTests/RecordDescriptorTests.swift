import Foundation
import Testing
@testable import SwiftRecords

struct DescriptorItem: Codable, Identifiable, Equatable {
    var id: Int
    var title: String
    var nickname: String?
    var rank: Int
    var score: Double?
    var created: Date
    var size: Size

    enum Size: String, Codable, Comparable, CaseIterable {
        case small, large, medium
        // Not by raw value, so SQL cannot match it.
        static func < (lhs: Size, rhs: Size) -> Bool {
            let order: [Size] = [.small, .medium, .large]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }
}

/// `fetch(_:in:)` with a ``RecordDescriptor`` returns what sorting every record in Swift
/// returns, whether SQLite sorts or Swift does.
@Suite struct RecordDescriptorTests {
    private static let words = ["file10", "File2", "file2", "éclair", "Eclair", "zebra", "Apple", "apple", "ä", "a", "b", "", "Zoë", "zoe", "Ångström", "angstrom", "item 9", "item 10", "ß", "ss"]
    static let items: [DescriptorItem] = (0..<120).map(item)

    private static func item(_ index: Int) -> DescriptorItem {
        let title = words[(index * 7) % words.count]
        let nickname: String? = index % 4 == 0 ? nil : words[(index * 3) % words.count]
        let rank = (index * 37) % 11 - 5
        let score: Double? = index % 5 == 0 ? nil : Double((index * 13) % 17) / 4 - 2
        let created = Date(timeIntervalSinceReferenceDate: Double((index * 101) % 97) * 3600 - 50_000)
        let sizes: [DescriptorItem.Size] = [.small, .large, .medium]
        return DescriptorItem(id: index, title: title, nickname: nickname, rank: rank, score: score, created: created, size: sizes[index % 3])
    }

    private func container() throws -> RecordContainer {
        let container = RecordContainer.inMemory(DescriptorItem.self)
        for item in Self.items { try container.save(our: item, zone: "Items") }
        return container
    }

    /// The sort keys of `items`, so records that tie compare equal whichever comes first.
    private func keys(_ items: [DescriptorItem], _ order: [SortDescriptor<DescriptorItem>]) -> [String] {
        items.map { item in order.map { descriptor in "\(descriptor.keyPath.map { item[keyPath: $0] } ?? "?")" }.joined(separator: "|") }
    }

    private func expectMatchesSwift(_ descriptor: RecordDescriptor<DescriptorItem>, translates: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let fetched = try container().fetch(descriptor, in: "Items")
        var expected = try Self.items.filter { try descriptor.predicate?.evaluate($0) ?? true }.sorted(using: descriptor.sortBy)
        expected = Array(expected.dropFirst(descriptor.fetchOffset ?? 0).prefix(descriptor.fetchLimit ?? .max))
        #expect((RecordContainer.orderBy(descriptor.sortBy) != nil) == translates, "Which path sorts.", sourceLocation: sourceLocation)
        #expect(keys(fetched, descriptor.sortBy) == keys(expected, descriptor.sortBy), sourceLocation: sourceLocation)
        #expect(fetched.count == expected.count, sourceLocation: sourceLocation)
    }

    @Test(arguments: [
        [SortDescriptor(\DescriptorItem.rank)],
        [SortDescriptor(\DescriptorItem.rank, order: .reverse)],
        [SortDescriptor(\DescriptorItem.score)],
        [SortDescriptor(\DescriptorItem.score, order: .reverse)],
        [SortDescriptor(\DescriptorItem.created)],
        [SortDescriptor(\DescriptorItem.rank), SortDescriptor(\DescriptorItem.created, order: .reverse)],
        [SortDescriptor(\DescriptorItem.title, comparator: .lexical)],
        [SortDescriptor(\DescriptorItem.title, comparator: .lexical, order: .reverse)],
        [SortDescriptor(\DescriptorItem.nickname, comparator: .lexical)],
        [SortDescriptor(\DescriptorItem.nickname, comparator: .lexical, order: .reverse), SortDescriptor(\DescriptorItem.rank)],
    ])
    func sqlSortsAsSwiftDoes(_ order: [SortDescriptor<DescriptorItem>]) throws {
        try expectMatchesSwift(RecordDescriptor(sortBy: order), translates: true)
        var page = RecordDescriptor(sortBy: order)
        page.fetchOffset = 17
        page.fetchLimit = 25
        try expectMatchesSwift(page, translates: true)
    }

    #if canImport(Darwin)
    @Test(arguments: [
        [SortDescriptor(\DescriptorItem.title)],
        [SortDescriptor(\DescriptorItem.title, order: .reverse)],
        [SortDescriptor(\DescriptorItem.title, comparator: .localized)],
        [SortDescriptor(\DescriptorItem.nickname), SortDescriptor(\DescriptorItem.rank)],
    ])
    func localizedStringsSortThroughTheirCollation(_ order: [SortDescriptor<DescriptorItem>]) throws {
        var page = RecordDescriptor(sortBy: order)
        page.fetchOffset = 5
        page.fetchLimit = 40
        try expectMatchesSwift(page, translates: true)
    }
    #endif

    @Test func anEnumWithItsOwnOrderSortsInSwift() throws {
        var page = RecordDescriptor<DescriptorItem>(sortBy: [SortDescriptor(\.size), SortDescriptor(\.rank)])
        page.fetchOffset = 10
        page.fetchLimit = 30
        try expectMatchesSwift(page, translates: false)
    }

    @Test func anExactPredicateFiltersInSQL() throws {
        var page = RecordDescriptor<DescriptorItem>(predicate: #Predicate { $0.rank > 0 }, sortBy: [SortDescriptor(\.created)])
        page.fetchLimit = 12
        #expect(RecordContainer.filter(for: page.predicate!)?.isExact == true)
        try expectMatchesSwift(page, translates: true)
    }

    @Test func aPredicateSwiftMustFinishStillPagesInOrder() throws {
        var page = RecordDescriptor<DescriptorItem>(predicate: #Predicate { $0.title.count > 3 }, sortBy: [SortDescriptor(\.rank, order: .reverse)])
        page.fetchOffset = 4
        page.fetchLimit = 9
        #expect(RecordContainer.filter(for: page.predicate!)?.isExact != true)
        try expectMatchesSwift(page, translates: true)
    }

    @Test func noSortStillLimits() throws {
        var page = RecordDescriptor<DescriptorItem>()
        page.fetchLimit = 7
        #expect(try container().fetch(page, in: "Items").count == 7)
    }

    @Test func excludedRowsAreLeftOut() throws {
        let container = try container()
        let names = try (0..<10).map { try RecordContainer.recordName(for: $0, type: "DescriptorItem") }
        let fetched = try container.fetch(RecordDescriptor<DescriptorItem>(sortBy: [SortDescriptor(\.id)]), in: "Items", excluding: names)
        #expect(fetched.first?.id == 10)
        #expect(fetched.count == Self.items.count - 10)
    }
}
