import Foundation
@testable import SwiftRecords
import Testing

struct Address: Codable, Hashable, Sendable {
    var street = "Elm"
    var city = "Oslo"
}

@Record
struct MergeContact {
    var id = UUID.ordered()
    var name = "Ann"
    var place = Address()
    var tags: Set<String> = ["family"]
    @Merged(.sum) var plays = 0
    @Merged(.keep(.theirs)) var rank = 0
    @Timestamped(.modified) var modified: Date?
}

/// Merges itself: a confirmed booking wins every conflict.
@Record
struct MergeBooking: Mergeable {
    var id = UUID.ordered()
    var note = ""
    var confirmed = false

    func merging(with theirs: MergeBooking, from base: MergeBooking) -> MergeBooking {
        confirmed ? self : theirs
    }
}

/// Merges itself, but gives up on a conflict, so the usual merge decides.
@Record
struct MergeTicket: Mergeable {
    var id = UUID.ordered()
    var seat = ""
    var place = Address()

    func merging(with theirs: MergeTicket, from base: MergeTicket) throws(MergeConflict<MergeTicket>) -> MergeTicket {
        throw MergeConflict(base: base, ours: self, theirs: theirs)
    }
}

/// Records edited on two devices merge as their type: nested values node by node, with `@Merged`
/// strategies, and a conflict going to the later edit.
@MainActor
@Suite struct RecordMergeTests {
    let server = TestServer()

    private func device() throws -> RecordContext {
        try RecordContainer(
            for: [MergeContact.self, MergeBooking.self, MergeTicket.self], inMemory: true, syncProvider: TestProvider(server: server)
        ).mainContext
    }

    /// Two devices that have both seen `record`.
    private func devices<R: Record>(_ record: R) async throws -> (RecordContext, RecordContext) {
        let phone = try device()
        let tablet = try device()
        phone.insert(record)
        try await phone.save()
        try await tablet.refresh()
        return (phone, tablet)
    }

    /// Commits each device's edit, then syncs the phone first, so the tablet's upload meets the phone's.
    private func sync(_ phone: RecordContext, _ tablet: RecordContext) async throws {
        try await phone.save()
        try await tablet.save()
        try await phone.refresh()
        try await tablet.refresh()
    }

    /// Commits without sending, as the synchronous `save()` does.
    private func commit(_ context: RecordContext) throws {
        try context.save()
    }

    private func contact(_ context: RecordContext, _ id: UUID) throws -> MergeContact {
        try #require(try context.container.fetch(MergeContact.self, id: id))
    }

    @Test func editsInsideOneValueOnTwoDevicesBothApply() async throws {
        let original = MergeContact()
        let (phone, tablet) = try await devices(original)
        var mine = original
        mine.place.street = "Oak"
        phone.insert(mine)
        var theirs = original
        theirs.place.city = "Bergen"
        tablet.insert(theirs)

        try await sync(phone, tablet)
        for device in [phone, tablet] {
            #expect(try contact(device, original.id).place == Address(street: "Oak", city: "Bergen"))
        }
    }

    @Test func setsKeepAdditionsAndRemovalsFromBoth() async throws {
        let original = MergeContact(tags: ["family", "friends"])
        let (phone, tablet) = try await devices(original)
        var mine = original
        mine.tags.insert("work")
        phone.insert(mine)
        var theirs = original
        theirs.tags.remove("family")
        tablet.insert(theirs)

        try await sync(phone, tablet)
        for device in [phone, tablet] {
            #expect(try contact(device, original.id).tags == ["friends", "work"])
        }
    }

    @Test func mergedStrategiesApply() async throws {
        let original = MergeContact()
        let (phone, tablet) = try await devices(original)
        var mine = original
        mine.plays += 2
        mine.rank = 1
        phone.insert(mine)
        var theirs = original
        theirs.plays += 3
        theirs.rank = 2
        tablet.insert(theirs)

        try await sync(phone, tablet)
        for device in [phone, tablet] {
            let merged = try contact(device, original.id)
            #expect(merged.plays == 5)
            // The tablet's upload met the phone's: theirs is the phone's.
            #expect(merged.rank == 1)
        }
    }

    @Test func aConflictGoesToTheLaterEditAndTheRestStillMerges() async throws {
        let original = MergeContact()
        let (phone, tablet) = try await devices(original)
        var mine = original
        mine.name = "Ann B."
        mine.place.street = "Oak"
        phone.insert(mine)
        try commit(phone)
        // Edit dates are compared, so the tablet's must be strictly later even on a fast machine.
        try await Task.sleep(for: .milliseconds(20))
        var theirs = original
        theirs.name = "Anne"
        theirs.place.city = "Bergen"
        tablet.insert(theirs)
        try commit(tablet)   // the later edit

        try await sync(phone, tablet)
        for device in [phone, tablet] {
            let merged = try contact(device, original.id)
            #expect(merged.name == "Anne")
            #expect(merged.place == Address(street: "Oak", city: "Bergen"))
        }
    }

    @Test func aRecordsOwnMergeDecides() async throws {
        let original = MergeBooking(note: "a")
        let (phone, tablet) = try await devices(original)
        var mine = original
        mine.note = "phone"
        mine.confirmed = true
        phone.insert(mine)
        var theirs = original
        theirs.note = "tablet"
        tablet.insert(theirs)

        try await sync(phone, tablet)
        for device in [phone, tablet] {
            let merged = try #require(try device.container.fetch(MergeBooking.self, id: original.id))
            #expect(merged.note == "phone")
            #expect(merged.confirmed)
        }
    }

    @Test func aRecordsOwnMergeThatThrowsFallsBackToTheUsualMerge() async throws {
        let original = MergeTicket(seat: "1A")
        let (phone, tablet) = try await devices(original)
        var mine = original
        mine.place.street = "Oak"
        phone.insert(mine)
        var theirs = original
        theirs.place.city = "Bergen"
        tablet.insert(theirs)

        try await sync(phone, tablet)
        for device in [phone, tablet] {
            #expect(try device.container.fetch(MergeTicket.self, id: original.id)?.place == Address(street: "Oak", city: "Bergen"))
        }
    }

    @Test func aSaveKeepsANestedChangeThatArrivedDuringTheEdit() async throws {
        let original = MergeContact()
        let (phone, tablet) = try await devices(original)
        var draft = try contact(tablet, original.id)
        draft.place.street = "Oak"
        tablet.insert(draft)

        var mine = original
        mine.place.city = "Bergen"
        phone.insert(mine)
        try await phone.save()
        try await tablet.refresh()

        try commit(tablet)
        #expect(try contact(tablet, original.id).place == Address(street: "Oak", city: "Bergen"))
    }

    // MARK: Fields

    private func fields(_ contact: MergeContact) throws -> SyncFields {
        let encoded = try RecordEncoder.encode(contact)
        var fields: SyncFields = [:]
        for (name, value) in encoded.columns where name != "id" && value != .null {
            guard let field = MergeContact.cachedSchema.field(named: name) else { continue }
            fields[name] = try RecordStore.syncValue(of: value, as: Swift.type(of: field.keyPath).valueType)
        }
        return fields
    }

    @Test func withoutABaseEveryDifferenceTakesTheFavoredSide() throws {
        let store = try device().container.initialStorage.store
        let local = try fields(MergeContact(name: "Ann B.", place: Address(street: "Oak")))
        let server = try fields(MergeContact(name: "Anne", place: Address(city: "Bergen")))
        let merged = store.mergeFields(MergeContact.self, local: local, server: server, base: nil, localIsLater: false)
        #expect(merged == server)
    }

    @Test func fieldsThisVersionDoesntKnowMergeFieldByField() throws {
        let store = try device().container.initialStorage.store
        let base = try fields(MergeContact())
        var local = try fields(MergeContact(place: Address(street: "Oak")))
        var server = try fields(MergeContact(place: Address(city: "Bergen")))
        local["nickname"] = .unknown(.string("A"))
        server["color"] = .unknown(.string("red"))
        let merged = store.mergeFields(MergeContact.self, local: local, server: server, base: base, localIsLater: false)
        #expect(merged["nickname"] == .unknown(.string("A")))
        #expect(merged["color"] == .unknown(.string("red")))
        #expect(merged["place"] == (try fields(MergeContact(place: Address(street: "Oak", city: "Bergen"))))["place"])
    }

    @Test func fieldsThatDontDecodeMergeFieldByField() throws {
        let store = try device().container.initialStorage.store
        let base = try fields(MergeContact())
        var local = try fields(MergeContact(name: "Ann B."))
        var server = try fields(MergeContact(name: "Anne"))
        local["place"] = .string("not an address")
        server["place"] = .string("nor this")
        let merged = store.mergeFields(MergeContact.self, local: local, server: server, base: base, localIsLater: true)
        #expect(merged["name"] == .string("Ann B."))
        #expect(merged["place"] == .string("not an address"))
    }
}
