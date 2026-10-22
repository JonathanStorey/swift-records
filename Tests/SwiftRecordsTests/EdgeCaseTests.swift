import Foundation
@testable import SwiftRecords
import Testing

@Record
struct Bag: Equatable {
    var id = UUID()
    var members: Set<String> = []
    var labels: [Int: String] = [:]
}

@Record
struct Measurement {
    var id = UUID()
    var count: UInt64 = 0
    var value: Double = 0
    var text = ""
    var blob = Data()
}

@Record
struct TreeFolder: Equatable {
    var id = UUID()
    var name: String
    var subfolders: [TreeFolder] = []
    @Reference(to: \TreeFolder.subfolders, action: .deleteSelf) var parent: TreeFolder.ID?
}

@Record("Dish")
struct DishV3 {
    var id = UUID()
    var title: String
    @Renamed(from: "minutes", "duration") var time: Int = 0
}

@Suite struct ValueEdgeCaseTests {
    let container = try! RecordContainer(zone: .inMemory)

    @Test func unorderedValuesDontLookLikeEdits() throws {
        let collection = Bag(
            members: Set((0..<50).map { "member \($0)" }),
            labels: Dictionary(uniqueKeysWithValues: (0..<50).map { ($0, "label \($0)") })
        )
        for _ in 0..<5 {
            // A fresh copy has its own hash seed order.
            let copy = Bag(id: collection.id, members: Set(Array(collection.members)), labels: Dictionary(uniqueKeysWithValues: Array(collection.labels)))
            try container.save(copy)
        }
        #expect(try container.metadata(Bag.self, id: collection.id)?.version == 1)
        #expect(try container.fetch(Bag.self, id: collection.id) == collection)
    }

    @Test func largeUnsignedIntegersRoundTripAndFilter() throws {
        let big = Measurement(count: .max)
        try container.save([big, Measurement(count: 5)])
        #expect(try container.fetch(Measurement.self, id: big.id)?.count == .max)
        #expect(try container.fetch(Measurement.self, where: #Predicate { $0.count > 10 }).map(\.id) == [big.id])
        let limit = UInt64.max
        #expect(try container.fetch(Measurement.self, where: #Predicate { $0.count == limit }).map(\.id) == [big.id])
    }

    @Test func stringsKeepEmbeddedNulsAndEmptiness() throws {
        let record = Measurement(text: "a\u{0}b")
        let empty = Measurement(text: "")
        try container.save([record, empty])
        #expect(try container.fetch(Measurement.self, id: record.id)?.text == "a\u{0}b")
        #expect(try container.fetch(Measurement.self, id: empty.id)?.text == "")
        #expect(try container.count(Measurement.self, where: #Predicate { $0.text == "" }) == 1)
    }

    @Test func emptyDataRoundTrips() throws {
        let record = Measurement(blob: Data())
        let full = Measurement(blob: Data([0, 1, 2]))
        try container.save([record, full])
        #expect(try container.fetch(Measurement.self, id: record.id)?.blob == Data())
        #expect(try container.fetch(Measurement.self, id: full.id)?.blob == Data([0, 1, 2]))
    }

    @Test func nanIsRejected() throws {
        #expect(throws: RecordsError.invalidValue(type: "Measurement", property: "value")) {
            try container.save(Measurement(value: .nan))
        }
        #expect(try container.fetch(Measurement.self).isEmpty)
    }
}

@Suite struct StoreEdgeCaseTests {
    let container = try! RecordContainer(zone: .inMemory)

    @Test func selfReferencingTreesSaveAndFetch() throws {
        let tree = TreeFolder(name: "Root", subfolders: [
            TreeFolder(name: "A", subfolders: [TreeFolder(name: "A1")]),
            TreeFolder(name: "B"),
        ])
        try container.save(tree)
        let fetched = try #require(try container.fetch(TreeFolder.self, id: tree.id))
        // Saving through the parents sets each child's reference.
        var expected = tree
        expected.subfolders[0].parent = tree.id
        expected.subfolders[0].subfolders[0].parent = tree.subfolders[0].id
        expected.subfolders[1].parent = tree.id
        #expect(fetched == expected)
    }

    @Test func trueCyclesThrowOnFetch() throws {
        let child = TreeFolder(name: "Child")
        let parent = TreeFolder(name: "Parent", subfolders: [child])
        try container.save(parent)
        // Point the child back at its parent through the link table, which no value type can express.
        try container.store.transaction {
            try container.store.db.run(
                "INSERT INTO \"TreeFolder.subfolders\" (owner, target, position, inverse_position) VALUES (?, ?, 0, 0)",
                [try ValueCoding.encode(child.id), try ValueCoding.encode(parent.id)]
            )
        }
        #expect(throws: RecordsError.cycle(type: "TreeFolder")) {
            try container.fetch(TreeFolder.self, id: parent.id)
        }
    }

    @Test func fetchingManyIDsKeepsTheirOrder() throws {
        let people = (0..<1_200).map { Person(name: "P\($0)") }
        try container.save(people)
        let ids = people.map(\.id).shuffled()
        #expect(try container.fetch(Person.self, ids: ids).map(\.id) == ids)
    }

    @Test func pagingEdges() throws {
        try container.save((0..<5).map { ToDo(title: "T\($0)") })
        let inMemory = #Predicate<ToDo> { $0.title.count > 0 }
        for predicate in [nil, inMemory] {
            let none = try container.fetch(ToDo.self, where: predicate, limit: 0, offset: 2)
            #expect(none.isEmpty)
            #expect(none.startIndex == 2)
            #expect(try container.fetch(ToDo.self, where: predicate, limit: 3, offset: 99).isEmpty)
            #expect(try container.fetch(ToDo.self, where: predicate, limit: 99, offset: 3).map(\.title) == ["T3", "T4"])
        }
    }

    @Test func chainedRenamesReachTheNewestName() throws {
        let oldest = DishV1(title: "Soup", minutes: 20)
        try container.save(oldest)
        _ = try container.fetch(DishV2.self)  // renames minutes to duration
        let middle = DishV2(title: "Stew", duration: 40)
        try container.save(middle)

        let dishes = try container.fetch(DishV3.self)
        #expect(dishes.map(\.time) == [20, 40])
    }

    @Test func manyDistinctStatementsStayCorrect() throws {
        let people = (0..<260).map { Person(name: "P\($0)") }
        try container.save(people)
        // Each count of IDs is a different statement, which overflows the statement cache.
        for count in 1...260 {
            #expect(try container.fetch(Person.self, ids: Array(people.prefix(count).map(\.id))).count == count)
        }
        #expect(try container.fetch(Person.self, ids: [people[0].id]).map(\.name) == ["P0"])
    }

    @Test func deletesByIDAndPredicate() throws {
        let todos = (0..<6).map { ToDo(title: "T\($0)", priority: $0 % 2, subtasks: [Subtask(title: "S\($0)")]) }
        try container.save(todos)

        try container.delete(ToDo.self, id: todos[0].id)
        try container.delete(ToDo.self, where: #Predicate { $0.priority == 1 })
        #expect(try container.fetch(ToDo.self).map(\.title) == ["T2", "T4"])
        // Delete rules ran for each one.
        #expect(try container.fetch(Subtask.self).map(\.title) == ["S2", "S4"])

        try container.delete(ToDo.self, where: #Predicate { $0.title.count > 0 })  // in memory
        #expect(try container.fetch(ToDo.self).isEmpty)
        #expect(try container.fetch(Subtask.self).isEmpty)
    }

    @Test func throwingTransactionLeavesNothing() async throws {
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await container.performBackgroundTask { context in
                try context.transaction {
                    try context.save((0..<20).map { Person(name: "P\($0)") })
                    throw Failure()
                }
            }
        }
        #expect(try container.fetch(Person.self).isEmpty)
        try container.save(Person(name: "After"))
        #expect(try container.fetch(Person.self).map(\.name) == ["After"])
    }
}

@MainActor
@Suite struct ContextEdgeCaseTests {
    let context = try! RecordContainer(zone: .inMemory).mainContext

    init() {
        context.autosaveEnabled = false
    }

    @Test func filteredApplyKeepsOthersInPlace() throws {
        let todos = (0..<6).map { ToDo(title: "T\($0)", done: $0 % 2 == 0) }
        context.apply(todos, replacing: [])
        try context.save()

        // A view showing only the done items reverses them.
        let done = todos.filter(\.done)
        context.apply(done.reversed(), replacing: done)
        try context.save()

        #expect(try context.fetch(ToDo.self).map(\.title) == ["T4", "T1", "T2", "T3", "T0", "T5"])
    }

    @Test func insertedRecordsTakeTheirPlaceInTheSameSave() throws {
        let first = [ToDo(title: "A"), ToDo(title: "B")]
        context.apply(first, replacing: [])
        try context.save()

        let second = [first[0], ToDo(title: "New"), first[1]]
        context.apply(second, replacing: first)
        context.save(ToDo(title: "Elsewhere"))
        try context.save()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["A", "New", "B", "Elsewhere"])
    }

    @Test func rollbackRefreshes() throws {
        context.rollback()
        #expect(context.changeCount == 0)  // nothing pending, nothing to refresh

        context.save(ToDo(title: "Discarded"))
        context.rollback()
        #expect(context.changeCount == 1)
        #expect(!context.hasChanges)
        #expect(try context.fetch(ToDo.self).isEmpty)
    }

    @Test func failedSaveKeepsChangesPending() throws {
        context.save(Measurement(value: .nan))
        context.save(Person(name: "Kept"))
        #expect(throws: RecordsError.invalidValue(type: "Measurement", property: "value")) { try context.save() }
        #expect(context.pendingChangeCount == 2)
        #expect(try context.container.fetch(Person.self).isEmpty)

        // Fixing the bad change lets the rest save.
        context.rollback()
        context.save(Person(name: "Kept"))
        try context.save()
        #expect(try context.container.fetch(Person.self).map(\.name) == ["Kept"])
    }

    @Test func deletesByIDAndPredicate() throws {
        let todos = (0..<4).map { ToDo(title: "T\($0)", priority: $0) }
        context.apply(todos, replacing: [])
        try context.save()

        context.delete(ToDo.self, id: todos[0].id)
        context.delete(ToDo.self, where: #Predicate { $0.priority >= 2 })
        try context.save()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["T1"])
    }

    @Test func backgroundDeletes() async throws {
        let container = context.container
        try container.save((0..<4).map { Person(name: "P\($0)") })
        try await container.performBackgroundTask { background in
            let first = try #require(try background.fetch(Person.self).first)
            try background.delete(Person.self, id: first.id)
            try background.delete(Person.self, where: #Predicate { $0.name == "P3" })
        }
        #expect(try await context.fetch(Person.self).map(\.name) == ["P1", "P2"])
    }

    @Test func deleteAllDataStartsOver() throws {
        let container = context.container
        try container.save(ToDo(title: "Old", owner: Person(name: "Sam")))
        context.save(ToDo(title: "Pending"))
        let token = try container.changeToken

        try container.deleteAllData()
        #expect(!context.hasChanges)
        #expect(try context.fetch(ToDo.self).isEmpty)
        #expect(try context.fetch(Person.self).isEmpty)
        #expect(try container.changes().isEmpty)

        // The store works again, with change tokens that never repeat.
        context.save(ToDo(title: "New"))
        try context.save()
        #expect(try context.fetch(ToDo.self).map(\.title) == ["New"])
        #expect(try container.changeToken > token)
    }

    @Test func concurrentBackgroundImportAndMainSaves() async throws {
        let container = context.container
        let importing = Task {
            try await container.performBackgroundTask { background in
                for batch in 0..<10 {
                    try background.transaction {
                        try background.save((0..<50).map { Person(name: "Import \(batch)-\($0)") })
                    }
                }
            }
        }
        for index in 0..<50 {
            context.save(ToDo(title: "Main \(index)"))
            try await context.save()
            await Task.yield()
        }
        try await importing.value
        #expect(try await context.count(Person.self) == 500)
        #expect(try await context.count(ToDo.self) == 50)
    }
}

@MainActor
@Suite struct SharedFileTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    @Test func containersOnOneFileShareAStore() async throws {
        let first = try RecordContainer(zone: "shared", directory: directory)
        let second = try RecordContainer(zone: "shared", directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(first.store === second.store)

        // A column the second container adds is visible to the first.
        try first.save(ToDo(title: "Plain"))
        try second.save(ToDo(title: "Owned", owner: Person(name: "Sam")))
        #expect(try first.fetch(ToDo.self).map { $0.owner?.name } == [nil, "Sam"])

        // A commit through one refreshes the other's context.
        let context = second.mainContext
        let before = context.changeCount
        try first.save(Person(name: "Ana"))
        for _ in 0..<100 where context.changeCount == before {
            await Task.yield()
        }
        #expect(context.changeCount > before)
    }

    #if canImport(Darwin)
    @Test func appGroupDirectory() {
        if let url = Zone.directory(appGroup: "group.example.records") {
            #expect(url.path.hasSuffix("Library/Application Support/Records"))
        }
    }
    #endif
}
