import Foundation
@testable import SwiftRecords
import Testing

/// A save or a sync from elsewhere merges into a record's unsaved edit as it arrives, so views show the
/// fields it changed while the edit keeps its own.
@MainActor
@Suite struct PushMergeTests {
    let context = try! RecordContainer(for: [MergeContact.self], inMemory: true).mainContext

    private func stored(_ id: UUID) throws -> MergeContact {
        try #require(try context.container.fetch(MergeContact.self, id: id))
    }

    /// Saves a change to the stored copy from elsewhere, as a sync would, and lets the context hear of it.
    private func push(_ id: UUID, _ change: (inout MergeContact) -> Void) async throws {
        var other = try stored(id)
        change(&other)
        try context.container.save(other)
        for _ in 0..<20 { await Task.yield() }
    }

    private func saved(_ contact: MergeContact) throws {
        context.insert(contact)
        try commit()
    }

    /// Commits without sending, as the synchronous `save()` does.
    private func commit() throws {
        try context.save()
    }

    @Test func anUnsavedEditShowsFieldsChangedElsewhere() async throws {
        var contact = MergeContact()
        try saved(contact)
        contact.name = "Bo"
        context.insert(contact)

        try await push(contact.id) { $0.place.city = "Bergen" }
        let current = try #require(try context.record(MergeContact.self, for: contact.id))
        #expect(current.name == "Bo")
        #expect(current.place.city == "Bergen")
        #expect(context.hasChanges)

        try commit()
        #expect(try stored(contact.id).name == "Bo")
        #expect(try stored(contact.id).place.city == "Bergen")
    }

    @Test func theEditKeepsAValueBothChangedAndTheRestMerges() async throws {
        var contact = MergeContact()
        try saved(contact)
        contact.name = "Bo"
        context.insert(contact)

        try await push(contact.id) {
            $0.name = "Cy"
            $0.tags.insert("work")
        }
        let current = try #require(try context.record(MergeContact.self, for: contact.id))
        #expect(current.name == "Bo")
        #expect(current.tags == ["family", "work"])
    }

    @Test func mergedValuesCountEachChangeOnce() async throws {
        var contact = MergeContact()
        try saved(contact)
        contact.plays += 2
        context.insert(contact)

        try await push(contact.id) { $0.plays += 3 }
        #expect(try context.record(MergeContact.self, for: contact.id)?.plays == 5)
        try await push(contact.id) { $0.plays += 1 }
        #expect(try context.record(MergeContact.self, for: contact.id)?.plays == 6)

        try commit()
        #expect(try stored(contact.id).plays == 6)
    }

    @Test func aLaterEditOfTheMergedRecordKeepsWhatArrived() async throws {
        var contact = MergeContact()
        try saved(contact)
        contact.name = "Bo"
        context.insert(contact)

        try await push(contact.id) { $0.place.city = "Bergen" }
        var current = try #require(try context.record(MergeContact.self, for: contact.id))
        current.place.street = "Oak"
        context.insert(current)

        try commit()
        #expect(try stored(contact.id).place == Address(street: "Oak", city: "Bergen"))
        #expect(try stored(contact.id).name == "Bo")
    }

    @Test func aRecordDeletedElsewhereKeepsTheEditUntilItSaves() async throws {
        var contact = MergeContact()
        try saved(contact)
        contact.name = "Bo"
        context.insert(contact)

        try context.container.delete(contact)
        for _ in 0..<20 { await Task.yield() }
        #expect(try context.record(MergeContact.self, for: contact.id)?.name == "Bo")

        try commit()
        #expect(try context.container.fetch(MergeContact.self, id: contact.id) == nil)
    }
}
