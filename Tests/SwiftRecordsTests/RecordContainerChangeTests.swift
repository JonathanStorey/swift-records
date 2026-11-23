import Foundation
import Testing
@testable import SwiftRecords
import Versioning
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title = ""
}

private extension RecordContainer {
    /// The `kind` of every row in the change log, oldest first.
    var loggedKinds: [String] {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(connection, "SELECT kind FROM record_change ORDER BY sequence", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var kinds: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            kinds.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return kinds
    }

    func save(their note: Note, zone: Zone = "Notes") throws(DatabaseError) {
        try save(their: try! JSONRepresentation(note), id: note.id, zone: zone, type: "Note", metadata: Data([1]))
    }
}

/// The change log: every committed change to a row, reported once per transaction.
@Suite struct RecordContainerChangeTests {
    private let note = Note(title: "First")
    private let notes = Zone("Notes")
    private var id: RecordContainer.RowID { RecordContainer.RowID(name: note.id, zone: notes) }

    @Test func aSaveIsReportedOnceItCommits() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var changes = container.changes().makeAsyncIterator()
        try container.save(our: note, zone: notes)

        let change = try #require(await changes.next())
        #expect(change.author == nil)
        #expect(change.ids == [id])
    }

    @Test func eachWriteIsLoggedWithItsKind() throws {
        let container = RecordContainer.inMemory(Note.self)
        try container.save(their: note)
        try container.save(our: note, zone: notes)
        try container.delete(our: note, zone: notes)
        try container.save(deleted: id)

        #expect(container.loggedKinds == ["insert", "update", "delete", "delete"],
                "Marking a row deleted and removing it are both deletes.")
    }

    @Test func theSyncEnginesWritesAreAuthoredSync() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var changes = container.changes().makeAsyncIterator()
        try container.save(their: note)
        try container.save(deleted: id)

        let saved = await changes.next(), deleted = await changes.next()
        #expect(saved?.author == RecordContainer.syncAuthor)
        #expect(deleted?.author == RecordContainer.syncAuthor)
    }

    @Test func aTransactionIsOneChangeWithItsAuthor() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let other = Note(title: "Second")
        var changes = container.changes().makeAsyncIterator()
        try container.transaction(author: "context") { () throws(DatabaseError) in
            do {
                try container.save(our: note, zone: notes)
                try container.save(our: other, zone: notes)
            } catch {
                throw DatabaseError(code: 1, description: "\(error)")
            }
        }

        let change = try #require(await changes.next())
        #expect(change.author == "context")
        #expect(change.ids == [id, RecordContainer.RowID(name: other.id, zone: notes)])
    }

    @Test func aNestedTransactionJoinsTheOuterOne() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var changes = container.changes().makeAsyncIterator()
        try container.transaction(author: "context") { () throws(DatabaseError) in
            try container.save(their: note)
        }

        let change = try #require(await changes.next())
        #expect(change.author == "context", "The outer transaction's author stands.")
        #expect(change.ids == [id])
    }

    @Test func aRollbackLogsAndReportsNothing() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let later = Note(title: "Later")
        var changes = container.changes().makeAsyncIterator()
        #expect(throws: DatabaseError.self) {
            try container.transaction { () throws(DatabaseError) in
                try container.save(their: note)
                throw DatabaseError(code: 1, description: "Stopped")
            }
        }
        #expect(container.loggedKinds.isEmpty)
        try container.save(our: later, zone: notes)

        let change = try #require(await changes.next())
        #expect(change.ids == [RecordContainer.RowID(name: later.id, zone: notes)], "Only the committed save is reported.")
    }

    @Test func clearReportsEveryRowAsOneChange() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let other = Note(title: "Second")
        try container.save(our: note, zone: notes)
        try container.save(our: other, zone: "Other")
        var changes = container.changes().makeAsyncIterator()
        try container.clear()

        let change = try #require(await changes.next())
        #expect(change.ids == [id, RecordContainer.RowID(name: other.id, zone: "Other")])
    }

    @Test func clearingAZoneReportsOnlyItsRows() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let shared = Zone("Notes", owner: "_friend")
        try container.save(our: note, zone: notes)
        try container.save(our: note, zone: shared)
        var changes = container.changes().makeAsyncIterator()
        try container.clear(in: shared)

        let change = try #require(await changes.next())
        #expect(change.ids == [RecordContainer.RowID(name: note.id, zone: shared)])
    }

    @Test func theSameRecordInTwoZonesIsTwoIDs() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let shared = Zone("Notes", owner: "_friend")
        var changes = container.changes().makeAsyncIterator()
        try container.transaction { () throws(DatabaseError) in
            try container.save(their: note)
            try container.save(their: note, zone: shared)
        }

        let change = try #require(await changes.next())
        #expect(change.ids == [id, RecordContainer.RowID(name: note.id, zone: shared)])
    }

    @Test func everyListenerHearsEachChange() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var first = container.changes().makeAsyncIterator()
        var second = container.changes().makeAsyncIterator()
        try container.save(our: note, zone: notes)

        let heard = (await first.next(), await second.next())
        #expect(heard.0?.ids == [id])
        #expect(heard.1?.ids == [id])
    }

    @Test func aCancelledListenerIsDropped() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let stream = container.changes()
        let listening = Task { for await _ in stream {} }
        listening.cancel()
        await listening.value

        #expect(container.locked { container.listeners.isEmpty })
    }

    @Test func anotherConnectionsCommitIsReportedAtTheNextCommit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".records")
        defer { try? FileManager.default.removeItem(at: url) }
        let mine = try RecordContainer(url: url), theirs = try RecordContainer(url: url)
        let other = Note(title: "Second")
        var changes = mine.changes().makeAsyncIterator()
        try theirs.transaction(author: "widget") { () throws(DatabaseError) in
            try theirs.save(their: note)
        }
        try mine.save(our: other, zone: notes)

        let first = await changes.next(), second = await changes.next()
        #expect(first?.author == "widget")
        #expect(first?.ids == [id])
        #expect(second?.ids == [RecordContainer.RowID(name: other.id, zone: notes)])
    }

    @Test func changesPurgedBeforeTheyWereReadReportEverything() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".records")
        defer { try? FileManager.default.removeItem(at: url) }
        let mine = try RecordContainer(url: url), theirs = try RecordContainer(url: url)
        var changes = mine.changes().makeAsyncIterator()
        try theirs.save(our: note, zone: notes)
        try theirs.purgeChanges(before: Date(timeIntervalSinceNow: 60))
        try mine.save(our: Note(title: "Second"), zone: notes)

        let change = try #require(await changes.next())
        #expect(change.ids == nil, "Any row may have changed.")
    }

    @Test func purgingKeepsTheLastHour() throws {
        let container = RecordContainer.inMemory(Note.self)
        try container.save(our: note, zone: notes)
        try container.purgeChanges()
        #expect(container.loggedKinds == ["insert"])

        try container.purgeChanges(before: Date(timeIntervalSinceNow: 60))
        #expect(container.loggedKinds.isEmpty)
    }
}

/// The public change history: ``RecordContainer/transactions(after:)`` and
/// ``RecordContainer/deleteTransactions(through:)``.
@Suite struct RecordTransactionTests {
    private let note = Note(title: "First")
    private let notes = Zone("Notes")
    private var id: RecordID<Any> { RecordID(name: note.id, zone: notes) }

    @Test func eachTransactionListsItsChangesInOrder() throws {
        let container = RecordContainer.inMemory(Note.self)
        let other = Note(title: "Second")
        let otherID = RecordID<Any>(name: other.id, zone: notes)
        let before = Date(timeIntervalSinceNow: -1)
        try container.save(their: note)
        try container.transaction(author: "context") { () throws(DatabaseError) in
            do {
                try container.save(our: note, zone: notes)
                try container.save(our: other, zone: notes)
            } catch {
                throw DatabaseError(code: 1, description: "\(error)")
            }
        }
        try container.delete(our: note, zone: notes)

        let transactions = try container.transactions()
        #expect(transactions.map(\.author) == [RecordContainer.syncAuthor, "context", nil])
        #expect(transactions.map(\.changes) == [
            [.inserted(id, type: "Note")],
            [.updated(id, type: "Note"), .inserted(otherID, type: "Note")],
            [.deleted(id, type: "Note")],
        ])
        #expect(transactions.map(\.id) == transactions.map(\.id).sorted())
        #expect(transactions.allSatisfy { $0.timestamp > before && $0.timestamp <= Date() })
    }

    @Test func afterSkipsWhatWasRead() throws {
        let container = RecordContainer.inMemory(Note.self)
        try container.save(our: note, zone: notes)
        let read = try container.transactions()
        try container.delete(our: note, zone: notes)

        let unread = try container.transactions(after: read.last?.id)
        #expect(unread.map(\.changes) == [[.deleted(id, type: "Note")]])
        let none = try container.transactions(after: unread.last?.id)
        #expect(none.isEmpty)
    }

    @Test func deletingThroughATransactionKeepsLaterOnes() throws {
        let container = RecordContainer.inMemory(Note.self)
        try container.save(our: note, zone: notes)
        let read = try container.transactions()
        try container.delete(our: note, zone: notes)
        try container.deleteTransactions(through: #require(read.last?.id))

        let kept = try container.transactions()
        #expect(kept.map(\.changes) == [[.deleted(id, type: "Note")]])
    }
}
