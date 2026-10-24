import Foundation
@testable import SwiftRecords
import Testing

@Suite struct SyncSupportTests {
    let container = try! RecordContainer(inMemory: true)

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
    let context = try! RecordContainer(inMemory: true).mainContext

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
        context.insert(Person(name: "Mine"))
        try await context.save()
        await settle()
        #expect(context.changeCount == before + 1)
    }

    @Test func backgroundWritesRefreshToo() async throws {
        let before = context.changeCount
        let count = try await context.container.performBackgroundTask { background in
            try background.transaction {
                try background.insert(Person(name: "Imported"))
                try background.insert(Person(name: "Also imported"))
            }
            return try background.fetchCount(RecordDescriptor<Person>())
        }
        await settle()
        #expect(count == 2)
        #expect(context.changeCount == before + 1)
        #expect(try context.fetch(Person.self).map(\.name) == ["Imported", "Also imported"])
    }
}

@Suite struct WireMemberTests {
    @Test func membersSliceEachValue() throws {
        let json = #" { "a" : 1 , "b":"x,}\"y" ,"c":[1,{"d":[2]}],"e":{"f":null}, "gA":true, "n": null, "z":-2.5e3 } "#
        let members = try WireJSON.members(of: Data(json.utf8)).mapValues { String(decoding: $0, as: UTF8.self) }
        #expect(members == ["a": "1", "b": #""x,}\"y""#, "c": #"[1,{"d":[2]}]"#, "e": #"{"f":null}"#, "gA": "true", "z": "-2.5e3"])
        #expect(try WireJSON.members(of: Data("{}".utf8)).isEmpty)
        for bad in ["", "[]", "{", #"{"a":}"#, #"{"a" 1}"#, #"{"a":1"#, #"{"a":1} x"#, #"{"a":"x}"#] {
            #expect(throws: (any Error).self) { try WireJSON.members(of: Data(bad.utf8)) }
        }
    }
}

@Suite struct ColumnFastPathTests {
    /// The shortcut for common primitives stores exactly what encoding the Swift value would.
    @Test func primitivesStoreAsTheirTypesWould() throws {
        let date = Date(timeIntervalSince1970: 1_234.5)
        #expect(try RecordStore.column(.string("a"), as: String.self) == ValueCoding.encode("a"))
        #expect(try RecordStore.column(.string("a"), as: String?.self) == ValueCoding.encode("a"))
        #expect(try RecordStore.column(.int(.max), as: Int.self) == ValueCoding.encode(Int.max))
        #expect(try RecordStore.column(.int(-3), as: Int64?.self) == ValueCoding.encode(Int64(-3)))
        #expect(try RecordStore.column(.double(2.5), as: Double.self) == ValueCoding.encode(2.5))
        #expect(try RecordStore.column(.bool(true), as: Bool.self) == ValueCoding.encode(true))
        #expect(try RecordStore.column(.bool(false), as: Bool?.self) == ValueCoding.encode(false))
        #expect(try RecordStore.column(.date(date), as: Date.self) == ValueCoding.encode(date))
        // Anything else still goes through its type, which checks it.
        #expect(try RecordStore.column(.int(7), as: Int8.self) == ValueCoding.encode(Int8(7)))
        #expect(throws: (any Error).self) { try RecordStore.column(.int(1_000), as: Int8.self) }
        #expect(throws: (any Error).self) { try RecordStore.column(.string("x"), as: Int.self) }
    }
}
