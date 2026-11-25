import Foundation
import Testing
@testable import SwiftRecords

/// `fetch(_:)` on a context returns what sorting the saved records, with the context's edits
/// applied, in Swift returns.
@MainActor @Suite struct RecordContextFetchTests {
    /// A context on the saved items with edits open: some changed, some deleted, some new.
    private func editedContext() throws -> (RecordContext, expected: [DescriptorItem]) {
        let container = RecordContainer.inMemory(DescriptorItem.self)
        for item in RecordDescriptorTests.items { try container.save(our: item, zone: "Items") }
        let context = container.mainContext
        context.zone = "Items"
        var expected = RecordDescriptorTests.items
        for index in stride(from: 0, to: expected.count, by: 9) {
            expected[index].rank = 100 - index
            expected[index].title = "edited \(index)"
            context.insert(expected[index])
        }
        for index in stride(from: 4, to: expected.count, by: 11) {
            context.delete(DescriptorItem.self, id: index)
        }
        expected.removeAll { $0.id % 11 == 4 }
        for index in 0..<15 {
            let new = DescriptorItem(id: 1000 + index, title: "new \(index)", nickname: nil, rank: index % 7 - 3, score: Double(index), created: Date(timeIntervalSinceReferenceDate: Double(index) * 7000 - 40_000), size: .medium)
            context.insert(new)
            expected.append(new)
        }
        // Open, but unchanged, so it still matches its saved value.
        context.delete(DescriptorItem.self, id: 1)
        context.insert(RecordDescriptorTests.items[1])
        return (context, expected)
    }

    private func expectMatchesSwift(_ descriptor: RecordDescriptor<DescriptorItem>, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let (context, all) = try editedContext()
        let fetched = try context.fetch(descriptor)
        var expected = try all.filter { try descriptor.predicate?.evaluate($0) ?? true }.sorted(using: descriptor.sortBy)
        expected = Array(expected.dropFirst(descriptor.fetchOffset ?? 0).prefix(descriptor.fetchLimit ?? .max))
        #expect(fetched.map(\.id) == expected.map(\.id), sourceLocation: sourceLocation)
    }

    @Test(arguments: [(nil, nil), (0, 10), (5, 20), (100, 50), (0, 0), (200, 10)] as [(Int?, Int?)])
    func editsSortIntoEachPage(offset: Int?, limit: Int?) throws {
        // `id` breaks every tie, so the order is one order.
        var page = RecordDescriptor<DescriptorItem>(sortBy: [SortDescriptor(\.rank, order: .reverse), SortDescriptor(\.id)])
        page.fetchOffset = offset
        page.fetchLimit = limit
        try expectMatchesSwift(page)
    }

    @Test func anExactPredicateIncludesTheEditsItMatches() throws {
        var page = RecordDescriptor<DescriptorItem>(predicate: #Predicate { $0.rank > 0 }, sortBy: [SortDescriptor(\.created), SortDescriptor(\.id)])
        page.fetchOffset = 3
        page.fetchLimit = 15
        try expectMatchesSwift(page)
    }

    @Test func aPredicateSwiftMustFinishIncludesTheEditsItMatches() throws {
        var page = RecordDescriptor<DescriptorItem>(predicate: #Predicate { $0.title.count > 5 }, sortBy: [SortDescriptor(\.rank), SortDescriptor(\.id)])
        page.fetchOffset = 2
        page.fetchLimit = 12
        try expectMatchesSwift(page)
    }

    @Test func aSortSwiftMustDoIncludesTheEdits() throws {
        var page = RecordDescriptor<DescriptorItem>(sortBy: [SortDescriptor(\.size), SortDescriptor(\.id, order: .reverse)])
        page.fetchOffset = 30
        page.fetchLimit = 40
        try expectMatchesSwift(page)
    }

    @Test func noSortReturnsEveryRecordOnce() throws {
        let (context, expected) = try editedContext()
        let fetched = try context.fetch(RecordDescriptor<DescriptorItem>())
        #expect(fetched.map(\.id).sorted() == expected.map(\.id).sorted())
        #expect(fetched.first { $0.id == 0 }?.title == "edited 0")
    }

    @Test func withoutPendingChangesOnlySavedRecordsReturn() throws {
        let (context, _) = try editedContext()
        var saved = RecordDescriptor<DescriptorItem>(sortBy: [SortDescriptor(\.id)])
        saved.includePendingChanges = false
        #expect(try context.fetch(saved).map(\.id) == RecordDescriptorTests.items.map(\.id))
    }

    @Test func afterSaveTheDatabaseAloneReturnsTheSame() throws {
        let (context, _) = try editedContext()
        let page = RecordDescriptor<DescriptorItem>(sortBy: [SortDescriptor(\.rank), SortDescriptor(\.id)])
        let before = try context.fetch(page)
        try context.save()
        var saved = page
        saved.includePendingChanges = false
        #expect(try context.fetch(saved).map(\.id) == before.map(\.id))
    }
}
