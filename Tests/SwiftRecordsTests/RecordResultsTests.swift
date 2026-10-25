import Foundation
@testable import SwiftRecords
import Testing

@MainActor
private final class Pages: RecordPager {
    var moves: [RecordPage] = []
    var refreshes = 0
    var saves = 0

    func move(to page: RecordPage) {
        moves.append(page)
    }

    func refresh() async throws {
        refreshes += 1
    }

    func save() throws {
        saves += 1
    }
}

@MainActor
@Suite struct RecordResultsTests {
    let todos = (0..<10).map { ToDo(title: "\($0)") }

    @Test func indicesArePositionsInTheFullResult() {
        let list = RecordResults(Array(todos[4..<8]), page: RecordPage(limit: 4, offset: 4), totalCount: 10)
        #expect(list.startIndex == 4)
        #expect(list.endIndex == 8)
        #expect(list[5].title == "5")
        #expect(list.map(\.title) == ["4", "5", "6", "7"])
        #expect(list.page == 1)
        #expect(list.pageCount == 3)
        #expect(list.hasPreviousPage)
        #expect(list.hasNextPage)
    }

    @Test func editsKeepTheOffset() {
        var list = RecordResults(Array(todos[4..<8]), page: RecordPage(limit: 4, offset: 4), totalCount: 10)
        list[6].title = "Six"
        list.remove(at: 4)
        list.append(ToDo(title: "New"))
        #expect(list.startIndex == 4)
        #expect(list.map(\.title) == ["5", "Six", "7", "New"])
    }

    @Test func pagingMovesThroughThePager() {
        let pages = Pages()
        let list = RecordResults(Array(todos[4..<8]), page: RecordPage(limit: 4, offset: 4), totalCount: 10, pager: pages)
        list.nextPage()
        list.previousPage()
        list.show(page: 9)
        list.show(page: 1)
        list.appendNextPage()
        #expect(pages.moves == [
            RecordPage(limit: 4, offset: 8), RecordPage(limit: 4, offset: 0), RecordPage(limit: 4, offset: 8),
            RecordPage(limit: 4, offset: 4, pages: 2),
        ])
    }

    @Test func appendNextPageKeepsThePageSize() {
        let pages = Pages()
        let list = RecordResults(Array(todos[0..<8]), page: RecordPage(limit: 4, pages: 2), totalCount: 10, pager: pages)
        #expect(list.fetchLimit == 4)
        #expect(list.hasNextPage)
        list.appendNextPage()
        list.nextPage()
        list.show(page: 0)
        #expect(pages.moves == [
            RecordPage(limit: 4, pages: 3), RecordPage(limit: 4, offset: 8), RecordPage(limit: 4, offset: 0),
        ])
        #expect(RecordPage(limit: 4, pages: 3).readLimit == 12)
    }

    @Test func pagingStopsAtTheEnds() {
        let pages = Pages()
        let last = RecordResults(Array(todos[8...]), page: RecordPage(limit: 4, offset: 8), totalCount: 10, pager: pages)
        last.nextPage()
        last.appendNextPage()
        #expect(!last.hasNextPage)
        let unlimited = RecordResults(todos, pager: pages)
        unlimited.nextPage()
        unlimited.appendNextPage()
        #expect(unlimited.pageCount == 1)
        #expect(unlimited.totalCount == 10)
        #expect(pages.moves.isEmpty)
    }

    @Test func refreshAndSaveReachThePager() async throws {
        let pages = Pages()
        let list = RecordResults(todos, pager: pages)
        try await list.refresh()
        try list.save()
        #expect(pages.refreshes == 1)
        #expect(pages.saves == 1)
    }
}
