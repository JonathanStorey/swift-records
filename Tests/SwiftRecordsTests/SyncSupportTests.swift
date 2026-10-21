import Foundation
@testable import SwiftRecords
import Testing

@Suite struct SyncSupportTests {
    let container = try! RecordContainer(zone: .inMemory)

    @Test func syncedWritesAreNotLoggedOrVersioned() throws {
        var person = Person(name: "From server")
        try container.applyingSyncedChanges {
            try container.save(person)
            try container.setTag(Data([9]), for: Person.self, id: person.id)
        }
        #expect(try container.changes().isEmpty)
        #expect(try container.metadata(Person.self, id: person.id)?.version == 0)
        #expect(try container.metadata(Person.self, id: person.id)?.tag == Data([9]))

        person.name = "Edited here"
        try container.save(person)
        #expect(try container.changes().map(\.id) == [person.id])
        #expect(try container.metadata(Person.self, id: person.id)?.version == 1)
    }

    @Test func syncedDeletesDropPendingEntriesThroughCascades() throws {
        let todo = ToDo(title: "Local", subtasks: [Subtask(title: "Child")])
        try container.save(todo)
        #expect(try container.changes().count == 2)

        try container.applyingSyncedChanges { try container.delete(todo) }
        #expect(try container.changes().isEmpty)
        #expect(try container.fetch(Subtask.self).isEmpty)
    }

    @Test func syncValuesRoundTripAndRollBack() throws {
        #expect(try container.syncValue(forKey: "state") == nil)
        try container.setSyncValue(Data([1]), forKey: "state")
        #expect(try container.syncValue(forKey: "state") == Data([1]))

        struct Abort: Error {}
        #expect(throws: Abort.self) {
            try container.transaction {
                try container.setSyncValue(Data([2]), forKey: "state")
                try container.setSyncValue(Data([3]), forKey: "token")
                throw Abort()
            }
        }
        #expect(try container.syncValue(forKey: "state") == Data([1]))
        #expect(try container.syncValue(forKey: "token") == nil)

        try container.setSyncValue(nil, forKey: "state")
        #expect(try container.syncValue(forKey: "state") == nil)
    }

    @Test func commitsCountOnlyWhenDataChanges() throws {
        let start = container.commitCount
        let person = Person(name: "Once")
        try container.save(person)
        #expect(container.commitCount == start + 1)
        try container.save(person)
        try container.setSyncValue(Data([1]), forKey: "x")
        #expect(container.commitCount == start + 1)
    }
}

@MainActor
@Suite struct OutsideChangeTests {
    let context = try! RecordContainer(zone: .inMemory).mainContext

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func outsideCommitsRefreshTheContext() async throws {
        let before = context.changeCount
        try context.container.applyingSyncedChanges {
            try context.container.save(Person(name: "Arrived"))
        }
        await settle()
        #expect(context.changeCount == before + 1)
        #expect(context.lastSaveSource == nil)
    }

    @Test func ownSavesRefreshOnce() async throws {
        let before = context.changeCount
        context.save(Person(name: "Mine"))
        try await context.save()
        await settle()
        #expect(context.changeCount == before + 1)
    }

    @Test func backgroundWritesRefreshToo() async throws {
        let before = context.changeCount
        let count = try await context.container.performBackgroundTask { background in
            try background.transaction {
                try background.save(Person(name: "Imported"))
                try background.save(Person(name: "Also imported"))
            }
            return try background.count(Person.self)
        }
        await settle()
        #expect(count == 2)
        #expect(context.changeCount == before + 1)
        #expect(try await context.fetch(Person.self).map(\.name) == ["Imported", "Also imported"])
    }
}
