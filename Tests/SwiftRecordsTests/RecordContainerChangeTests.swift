import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Note: Codable, Identifiable, Mergeable {
    var id = UUID()
    var title = ""
}

private extension RecordContainer {
    func save(their note: Note, zone: Zone = "Notes") throws(DatabaseError) {
        try save(their: try! JSONRepresentation(note), id: note.id, zone: zone, type: "Note", metadata: Data([1]))
    }
}

/// ``RecordContainer/transactions()``: every committed transaction, reported once, with its changes.
@Suite struct RecordContainerChangeTests {
    private let note = Note(title: "First")
    private let notes = Zone("Notes")
    private var id: RecordID<Any> { RecordID(name: note.id, zone: notes) }

    @Test func aSaveIsReportedOnceItCommits() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var transactions = container.transactions().makeAsyncIterator()
        let before = Date()
        try container.save(our: note, zone: notes)

        let transaction = try #require(await transactions.next())
        #expect(transaction.id == 1)
        #expect(transaction.author == nil)
        #expect(transaction.changes == [.inserted(id, type: "Note")])
        #expect(transaction.timestamp >= before && transaction.timestamp <= Date())
    }

    @Test func eachWriteIsReportedWithItsKind() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var transactions = container.transactions().makeAsyncIterator()
        try container.save(their: note)
        try container.save(our: note, zone: notes)
        try container.delete(our: note, zone: notes)
        try container.save(deleted: id)

        var changes: [RecordTransaction.Change] = []
        for _ in 1...4 { changes += await transactions.next()?.changes ?? [] }
        #expect(changes == [.inserted(id, type: "Note"), .updated(id, type: "Note"), .deleted(id, type: "Note"), .deleted(id, type: "Note")],
                "Marking a row deleted and removing it are both deletes.")
    }

    @Test func aNewRecordSavedAndDeletedBeforeSyncingIsInsertedThenDeleted() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var transactions = container.transactions().makeAsyncIterator()
        try container.save(our: note, zone: notes)
        try container.delete(our: note, zone: notes)

        let saved = await transactions.next(), deleted = await transactions.next()
        #expect(saved?.changes == [.inserted(id, type: "Note")])
        #expect(deleted?.changes == [.deleted(id, type: "Note")])
        #expect(deleted?.id == 2)
    }

    @Test func theSyncEnginesWritesAreAuthoredSync() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var transactions = container.transactions().makeAsyncIterator()
        try container.save(their: note)
        try container.save(deleted: id)

        let saved = await transactions.next(), deleted = await transactions.next()
        #expect(saved?.author == RecordContainer.syncAuthor)
        #expect(deleted?.author == RecordContainer.syncAuthor)
    }

    @Test func aTransactionIsOneElementWithItsAuthor() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let other = Note(title: "Second")
        var transactions = container.transactions().makeAsyncIterator()
        try container.transaction(author: "context") { () throws(DatabaseError) in
            do {
                try container.save(our: note, zone: notes)
                try container.save(our: other, zone: notes)
            } catch {
                throw DatabaseError(code: 1, description: "\(error)")
            }
        }

        let transaction = try #require(await transactions.next())
        #expect(transaction.author == "context")
        #expect(transaction.changes == [.inserted(id, type: "Note"), .inserted(RecordID(name: other.id, zone: notes), type: "Note")])
    }

    @Test func aNestedTransactionJoinsTheOuterOne() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var transactions = container.transactions().makeAsyncIterator()
        try container.transaction(author: "context") { () throws(DatabaseError) in
            try container.save(their: note)
        }

        let transaction = try #require(await transactions.next())
        #expect(transaction.author == "context", "The outer transaction's author stands.")
        #expect(transaction.changes == [.inserted(id, type: "Note")])
    }

    @Test func aRollbackReportsNothing() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let later = Note(title: "Later")
        var transactions = container.transactions().makeAsyncIterator()
        #expect(throws: DatabaseError.self) {
            try container.transaction { () throws(DatabaseError) in
                try container.save(their: note)
                throw DatabaseError(code: 1, description: "Stopped")
            }
        }
        try container.save(our: later, zone: notes)

        let transaction = try #require(await transactions.next())
        #expect(transaction.id == 1)
        #expect(transaction.changes == [.inserted(RecordID(name: later.id, zone: notes), type: "Note")], "Only the committed save is reported.")
    }

    @Test func aWriteThatChangesNothingReportsNothing() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var transactions = container.transactions().makeAsyncIterator()
        try container.delete(our: note, zone: notes)
        try container.save(our: note, zone: notes)

        let transaction = try #require(await transactions.next())
        #expect(transaction.changes == [.inserted(id, type: "Note")], "Deleting a record the container lacks is not a change.")
    }

    @Test func clearReportsEveryRowAsOneTransaction() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let other = Note(title: "Second")
        try container.save(our: note, zone: notes)
        try container.save(our: other, zone: "Other")
        var transactions = container.transactions().makeAsyncIterator()
        try container.clear()

        let transaction = try #require(await transactions.next())
        #expect(Set(transaction.changes) == [.deleted(id, type: "Note"), .deleted(RecordID(name: other.id, zone: "Other"), type: "Note")])
    }

    @Test func clearingAZoneReportsOnlyItsRows() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let shared = Zone("Notes", owner: "_friend")
        try container.save(our: note, zone: notes)
        try container.save(our: note, zone: shared)
        var transactions = container.transactions().makeAsyncIterator()
        try container.clear(in: shared)

        let transaction = try #require(await transactions.next())
        #expect(transaction.changes == [.deleted(RecordID(name: note.id, zone: shared), type: "Note")])
    }

    @Test func clearingAZoneToResendReportsUpdates() async throws {
        let container = RecordContainer.inMemory(Note.self)
        try container.save(their: note)
        var transactions = container.transactions().makeAsyncIterator()
        try container.clear(in: notes, resending: true)

        let transaction = try #require(await transactions.next())
        #expect(transaction.changes == [.updated(id, type: "Note")])
    }

    @Test func theSameRecordInTwoZonesIsTwoChanges() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let shared = Zone("Notes", owner: "_friend")
        var transactions = container.transactions().makeAsyncIterator()
        try container.transaction { () throws(DatabaseError) in
            try container.save(their: note)
            try container.save(their: note, zone: shared)
        }

        let transaction = try #require(await transactions.next())
        #expect(transaction.changes.map(\.id) == [id, RecordID(name: note.id, zone: shared)])
    }

    @Test func everyListenerHearsEachTransaction() async throws {
        let container = RecordContainer.inMemory(Note.self)
        var first = container.transactions().makeAsyncIterator()
        var second = container.transactions().makeAsyncIterator()
        try container.save(our: note, zone: notes)

        let heard = (await first.next(), await second.next())
        #expect(heard.0?.changes == [.inserted(id, type: "Note")])
        #expect(heard.1 == heard.0)
    }

    @Test func aCancelledListenerIsDropped() async throws {
        let container = RecordContainer.inMemory(Note.self)
        let stream = container.transactions()
        let listening = Task { for await _ in stream {} }
        listening.cancel()
        await listening.value

        #expect(container.locked { container.listeners.isEmpty })
    }
}

/// Two connections to one file, as an app and its widget in an app group have.
@Suite struct RecordContainerSharedFileTests {
    private let note = Note(title: "First")
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".records")

    @Test func anotherConnectionsCommitIsReportedAsExternal() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let app = try RecordContainer(url: url), widget = try RecordContainer(url: url)
        var transactions = app.transactions().makeAsyncIterator()
        try widget.save(our: note, zone: "Notes")
        widget.receiveExternalChange()
        app.receiveExternalChange()
        app.receiveExternalChange()
        try app.save(our: Note(title: "Second"), zone: "Notes")

        let external = await transactions.next(), own = await transactions.next()
        #expect(external?.author == RecordContainer.externalAuthor)
        #expect(external?.changes == [])
        #expect(own?.author == nil, "The widget's own notification and a repeated one report nothing.")
        #expect(own?.changes.count == 1)
    }

    @Test func aSecondWriterWaitsForTheFirst() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let app = try RecordContainer(url: url), widget = try RecordContainer(url: url)
        try app.execute("BEGIN IMMEDIATE")
        let saving = Task.detached { [note] in try widget.save(our: note, zone: "Notes") }
        try await Task.sleep(nanoseconds: 200_000_000)
        try app.execute("COMMIT")

        try await saving.value
        #expect(try app.row(id: RecordContainer.RowID(name: note.id, zone: "Notes")) != nil)
    }

    #if canImport(notify)
    @Test(.timeLimit(.minutes(1))) func anotherConnectionsCommitArrivesByDarwinNotification() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let app = try RecordContainer(url: url), widget = try RecordContainer(url: url)
        var transactions = app.transactions().makeAsyncIterator()
        try widget.save(our: note, zone: "Notes")

        let external = await transactions.next()
        #expect(external?.author == RecordContainer.externalAuthor)
    }
    #endif
}
