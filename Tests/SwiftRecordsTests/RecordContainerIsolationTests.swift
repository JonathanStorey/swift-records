import Foundation
import Testing
@testable import SwiftRecords

private struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
}

/// Reads outside a transaction see only what is committed, and sync bookkeeping stays quiet.
@Suite struct RecordContainerIsolationTests {
    private func fileContainer() throws -> RecordContainer {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try RecordContainer(for: [Entry.self], url: folder.appendingPathComponent("test.records"))
    }

    @Test func aReadOnAnotherThreadSeesOnlyWhatIsCommitted() throws {
        let container = try fileContainer()
        let committed = Entry(title: "Committed")
        try container.save(our: committed, zone: "Entries")
        let opened = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        Thread {
            try? container.transaction { () throws(DatabaseError) in
                try? container.save(our: Entry(title: "Uncommitted"), zone: "Entries")
                opened.signal()
                read.wait()
                throw DatabaseError(code: 1, description: "Rolled back on purpose.")
            }
            finished.signal()
        }.start()
        opened.wait()
        // On the writer's connection this would see the open transaction's row, or wait for it.
        let seen = try container.fetch(Entry.self, in: "Entries")
        read.signal()
        finished.wait()

        #expect(seen == [committed])
        #expect(try container.fetch(Entry.self, in: "Entries") == [committed])
    }

    @Test func aReadInsideATransactionSeesItsOwnWrites() throws {
        let container = try fileContainer()
        let entry = Entry(title: "New")
        let seen = try container.transaction { () throws(DatabaseError) -> [Entry] in
            try? container.save(our: entry, zone: "Entries")
            return (try? container.fetch(Entry.self, in: "Entries")) ?? []
        }
        #expect(seen == [entry])
    }

    @Test func syncBookkeepingIsNotReported() async throws {
        let container = RecordContainer.inMemory(Entry.self)
        let entry = Entry(title: "Sent")
        try container.save(our: entry, zone: "Entries")
        var transactions = container.transactions().makeAsyncIterator()
        let id = RecordContainer.RowID(name: entry.id.uuidString, zone: "Entries")
        try container.update(id: id) { $0.sent = $0.ours }
        try container.update(id: id) { $0.metadata = Data([1]) }
        try container.save(our: Entry(id: entry.id, title: "Edited"), zone: "Entries")

        let next = try #require(await transactions.next())
        #expect(next.author == nil, "The first report is the edit, not the bookkeeping before it.")
        #expect(next.changes == [.updated(id, type: "Entry")])
    }

    @Test func clearingIsTheSyncEnginesWork() async throws {
        let container = RecordContainer.inMemory(Entry.self)
        try container.save(our: Entry(), zone: "Entries")
        var transactions = container.transactions().makeAsyncIterator()
        try container.clear(in: "Entries")
        try container.clear()
        #expect(await transactions.next()?.author == RecordContainer.syncAuthor)
    }
}
