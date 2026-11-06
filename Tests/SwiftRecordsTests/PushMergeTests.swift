import Foundation
@testable import SwiftRecords
import Testing

/// A save or a sync from elsewhere merges into a record's unsaved edit as it arrives, so views show the
/// fields it changed while the edit keeps its own.
@MainActor
@Suite struct PushMergeTests {
    let context = try! RecordContainer(for: [MergeContact.self, MergeTicket.self], inMemory: true).mainContext

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

    @Test func aRecordDeletedElsewhereDropsTheEdit() async throws {
        var contact = MergeContact()
        try saved(contact)
        contact.name = "Bo"
        context.insert(contact)

        try context.container.delete(contact)
        for _ in 0..<20 { await Task.yield() }
        // A delete wins. An open `@Recordable` keeps the edit for its user to restore.
        #expect(try context.record(MergeContact.self, for: contact.id) == nil)
        #expect(!context.hasChanges)

        try commit()
        #expect(try context.container.fetch(MergeContact.self, id: contact.id) == nil)
    }

    @Test func theStoreKnowsWhichRowsEachCommitWrote() async throws {
        let store = context.container.initialStorage.store
        let first = MergeContact()
        try context.container.save(first)
        let start = store.commitCount
        let second = MergeContact()
        try context.container.save(second)
        // An edit of any other record has nothing to merge, so the context reads only these.
        #expect(store.rowsChanged(after: start) == [RowKey(table: MergeContact.table, id: try second.sqlID)])
        #expect(store.rowsChanged(after: store.commitCount) == [])
        // A delete can remove more than it names, so every edit is checked.
        try context.container.delete(first)
        #expect(store.rowsChanged(after: start) == nil)
    }

    @Test func aChangeToAnotherRecordLeavesTheConflict() async throws {
        let contact = try await conflictingEdit()
        try context.container.save(MergeContact(name: "Di"))
        for _ in 0..<20 { await Task.yield() }
        #expect(context.conflict(MergeContact.self, for: contact.id, at: \.name))
        #expect(try context.record(MergeContact.self, for: contact.id)?.place.city == "Bergen")
    }

    // MARK: Conflicts

    /// An edit of the name, then a push that also changes it, and the city.
    private func conflictingEdit() async throws -> MergeContact {
        var contact = MergeContact()
        try saved(contact)
        contact.name = "Bo"
        context.insert(contact)
        try await push(contact.id) {
            $0.name = "Cy"
            $0.place.city = "Bergen"
        }
        return contact
    }

    @Test func aConflictKeepsTheStoredCopy() async throws {
        let contact = try await conflictingEdit()
        let other = try #require(context.conflict(MergeContact.self, for: contact.id))
        #expect(other.name == "Cy")
        #expect(context.conflict(MergeContact.self, for: contact.id, at: \.name))
        #expect(!context.conflict(MergeContact.self, for: contact.id, at: \.place))
        #expect(try context.record(MergeContact.self, for: contact.id)?.name == "Bo")
    }

    @Test func changesThatMergeAreNoConflict() async throws {
        var contact = MergeContact()
        try saved(contact)
        contact.plays += 2
        contact.place.street = "Oak"
        context.insert(contact)
        try await push(contact.id) {
            $0.plays += 3
            $0.place.city = "Bergen"
        }
        #expect(context.conflict(MergeContact.self, for: contact.id) == nil)
    }

    @Test func resolvingForTheirsTakesTheConflictingValuesOnly() async throws {
        var contact = try await conflictingEdit()
        contact = try #require(try context.record(MergeContact.self, for: contact.id))
        contact.tags.insert("work")
        context.insert(contact)
        // A later edit keeps the conflict.
        #expect(context.conflict(MergeContact.self, for: contact.id) != nil)

        context.resolveConflict(MergeContact.self, for: contact.id, favoring: .theirs)
        #expect(context.conflict(MergeContact.self, for: contact.id) == nil)
        let current = try #require(try context.record(MergeContact.self, for: contact.id))
        #expect(current.name == "Cy")
        #expect(current.tags == ["family", "work"])

        try commit()
        #expect(try stored(contact.id).name == "Cy")
        #expect(try stored(contact.id).tags == ["family", "work"])
        #expect(try stored(contact.id).place.city == "Bergen")
    }

    @Test func resolvingForOursKeepsTheEdit() async throws {
        let contact = try await conflictingEdit()
        context.resolveConflict(MergeContact.self, for: contact.id, favoring: .ours)
        #expect(context.conflict(MergeContact.self, for: contact.id) == nil)
        try commit()
        #expect(try stored(contact.id).name == "Bo")
    }

    @Test func savingClearsTheConflict() async throws {
        let contact = try await conflictingEdit()
        try commit()
        #expect(context.conflict(MergeContact.self, for: contact.id) == nil)
        #expect(try stored(contact.id).name == "Bo")
        #expect(try stored(contact.id).place.city == "Bergen")
    }

    @Test func aConflictClearsOnceTheEditAgreesWithTheStoredCopy() async throws {
        var contact = try await conflictingEdit()
        contact = try #require(try context.record(MergeContact.self, for: contact.id))
        contact.name = "Cy"
        context.insert(contact)
        #expect(context.conflict(MergeContact.self, for: contact.id) == nil)
    }

    @Test func aMergeableThatThrowsReportsAConflict() async throws {
        var ticket = MergeTicket(seat: "1A")
        context.insert(ticket)
        try commit()
        ticket.seat = "2B"
        context.insert(ticket)
        var other = try #require(try context.container.fetch(MergeTicket.self, id: ticket.id))
        other.seat = "3C"
        try context.container.save(other)
        for _ in 0..<20 { await Task.yield() }
        #expect(context.conflict(MergeTicket.self, for: ticket.id, at: \.seat))
        #expect(try context.record(MergeTicket.self, for: ticket.id)?.seat == "2B")
    }

    @Test func aMergeableThatMergesReportsNoConflict() async throws {
        let container = try RecordContainer(for: [MergeBooking.self], inMemory: true)
        let context = container.mainContext
        var booking = MergeBooking(note: "a")
        try container.save(booking)
        booking.note = "b"
        booking.confirmed = true
        context.insert(booking)
        var other = try #require(try container.fetch(MergeBooking.self, id: booking.id))
        other.note = "c"
        try container.save(other)
        for _ in 0..<20 { await Task.yield() }
        #expect(context.conflict(MergeBooking.self, for: booking.id) == nil)
    }
}
