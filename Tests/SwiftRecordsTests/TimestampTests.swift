import Foundation
@testable import SwiftRecords
import Testing

@Record
struct Journal {
    var id = UUID()
    var text: String
    @Timestamp(.created) var created: Date?
    @Timestamp(.modified) var modified: Date?
    @Timestamp(.synced) var synced: Date?
}

@Suite struct TimestampTests {
    let container = try! RecordContainer(for: [Journal.self], inMemory: true)

    @Test func savesStampCreatedAndModified() throws {
        let start = Date()
        var entry = Journal(text: "First")
        #expect(entry.created == nil)
        try container.save(entry)
        entry = try #require(try container.fetch(Journal.self, id: entry.id))
        let created = try #require(entry.created)
        #expect(created >= start)
        #expect(entry.modified == created)
        #expect(entry.synced == nil)

        // Saving unchanged keeps both.
        try container.save(entry)
        #expect(try container.fetch(Journal.self, id: entry.id)?.modified == created)

        entry.text = "Second"
        try container.save(entry)
        let edited = try #require(try container.fetch(Journal.self, id: entry.id))
        #expect(edited.created == created)
        #expect(try #require(edited.modified) > created)

        // A copy saved without its timestamps keeps the stored ones.
        try container.save(Journal(id: entry.id, text: "Third"))
        #expect(try container.fetch(Journal.self, id: entry.id)?.created == created)
    }

    @Test func modifiedWorksInPredicatesAndSyncedInMemory() throws {
        try container.save(Journal(text: "A"))
        let cutoff = Date.distantPast
        #expect(try container.fetch(Journal.self, where: #Predicate { $0.modified! > cutoff }).count == 1)
        #expect(try container.fetch(Journal.self, where: #Predicate { $0.synced == nil }).count == 1)
        #expect(!container.defaultStorage.store.columns["Journal", default: []].contains("synced"))
    }

    @Test func encodesAsPlainDatesOutsideAContainer() throws {
        try container.save(Journal(text: "JSON"))
        let entry = try #require(try container.fetch(Journal.self).first)
        let decoded = try JSONDecoder().decode(Journal.self, from: JSONEncoder().encode(entry))
        #expect(decoded.created == entry.created)
        #expect(decoded.modified == entry.modified)
    }
}

@MainActor
@Suite struct SyncedTimestampTests {
    let server = TestServer()

    private func device() throws -> (TestProvider, RecordContext) {
        let provider = TestProvider(server: server)
        let context = try RecordContainer(for: [Journal.self], inMemory: true, syncProvider: { _ in provider }).mainContext
        context.autosaveEnabled = false
        return (provider, context)
    }

    /// In async code the compiler picks the async `save()`, which sends.
    private func commit(_ context: RecordContext) throws {
        try context.save()
    }

    @Test func syncedFollowsTheServer() async throws {
        let (_, phone) = try device()
        let (_, tablet) = try device()
        try await phone.refresh()   // open the provider first, which sends what is pending
        var entry = Journal(text: "Hello")
        phone.save(entry)
        try commit(phone)   // committed, not sent
        #expect(try phone.container.fetch(Journal.self, id: entry.id)?.synced == nil)

        try await phone.save()
        entry = try #require(try await phone.fetch(Journal.self, id: entry.id))
        #expect(entry.synced != nil)

        entry.text = "Hello again"
        phone.save(entry)
        try commit(phone)
        #expect(try phone.container.fetch(Journal.self, id: entry.id)?.synced == nil)
        try await phone.save()
        let sent = try #require(try await phone.fetch(Journal.self, id: entry.id))
        #expect(sent.synced != nil)

        // The other device gets the same created and modified times, to the millisecond a server keeps,
        // and its own synced time.
        try await tablet.refresh()
        let received = try #require(try await tablet.fetch(Journal.self, id: entry.id))
        let milliseconds = { (date: Date?) in date.map { ($0.timeIntervalSince1970 * 1000).rounded() } }
        #expect(milliseconds(received.created) == milliseconds(sent.created))
        #expect(milliseconds(received.modified) == milliseconds(sent.modified))
        #expect(received.created?.timeIntervalSince1970 == milliseconds(sent.created).map { $0 / 1000 })
        #expect(received.synced != nil)
        #expect(!server.has("Journal", entry.id, "synced"))
    }
}
