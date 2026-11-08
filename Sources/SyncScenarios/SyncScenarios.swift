import Foundation
import SwiftRecords

/// A sync scenario: something people do on two devices, and what each device should see afterwards. Each
/// one runs the same way on any `SyncBackend`.
public struct SyncScenario: Sendable, CustomStringConvertible {
    public let name: String
    /// Whether it needs a backend that can go offline.
    public let needsOffline: Bool
    let body: @MainActor @Sendable (any SyncBackend, Zone) async throws -> Void

    init(
        _ name: String, needsOffline: Bool = false,
        _ body: @escaping @MainActor @Sendable (any SyncBackend, Zone) async throws -> Void
    ) {
        self.name = name
        self.needsOffline = needsOffline
        self.body = body
    }

    public var description: String { name }

    /// Runs the scenario in a zone of its own and removes it from the server afterwards. Throws
    /// `ScenarioFailure` for a check that didn't hold, or the error a save or refresh threw.
    @MainActor
    public func run(on backend: any SyncBackend) async throws {
        let zone = try backend.freshZone()
        do {
            try await body(backend, zone)
        } catch {
            await backend.cleanUp(zone)
            throw error
        }
        await backend.cleanUp(zone)
    }
}

extension SyncBackend {
    /// Two devices on the same account, both in `zone`.
    func pair(_ zone: Zone) throws -> (RecordContainer, RecordContainer) {
        (try makeDevice(scenarioTypes, zone: zone), try makeDevice(scenarioTypes, zone: zone))
    }
}

@MainActor
extension RecordContainer {
    var context: RecordContext { mainContext }

    /// Saves without sending, as the synchronous `save()` does.
    func commit() throws {
        try mainContext.save()
    }

    func note(_ id: UUID) throws -> ScenarioNote? {
        try mainContext.record(ScenarioNote.self, for: id)
    }

    func notebook(_ id: UUID) throws -> ScenarioNotebook? {
        try mainContext.record(ScenarioNotebook.self, for: id)
    }
}

public enum SyncScenarios {
    /// Every scenario, in the order a report lists them.
    public static let all: [SyncScenario] = [
        recordsArrive, editsArrive, deletionsTakeChildren, separateEditsMerge, laterEditWins,
        childrenFromTwoDevices, linksArrive, attachmentsArrive, manyRecordsArrive, offlineEditsSend,
    ]

    /// The scenario with this name.
    public static func named(_ name: String) -> SyncScenario? {
        all.first { $0.name == name }
    }

    static let recordsArrive = SyncScenario("A new notebook and its notes arrive on another device") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let notebook = ScenarioNotebook(
            title: "Groceries", color: "green",
            notes: [
                ScenarioNote(text: "Milk", position: 0, words: ["dairy"], due: due),
                ScenarioNote(text: "Bread", position: 1, pinned: true),
            ]
        )
        phone.context.insert(notebook)
        try await phone.context.save()

        try await backend.eventually(laptop, "the notebook never arrived") {
            try laptop.notebook(notebook.id)?.notes.count == 2
        }
        let received = try laptop.notebook(notebook.id)!
        try check(received.title == "Groceries" && received.color == "green", "fields differ: \(received)")
        try check(received.notes.map(\.text) == ["Milk", "Bread"], "notes out of order: \(received.notes.map(\.text))")
        try check(received.notes[0].words == ["dairy"], "an array field differs")
        try check(received.notes[0].due == due, "a date field differs")
        try check(received.notes[1].pinned, "a Bool field differs")
        try check(laptop.context.status == .saved, "the receiving device shows \(laptop.context.status)")
    }

    static let editsArrive = SyncScenario("An edit arrives on another device") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        var note = ScenarioNote(text: "Call the plumber")
        phone.context.insert(note)
        try await phone.context.save()
        try await backend.eventually(laptop, "the note never arrived") { try laptop.note(note.id) != nil }

        note.text = "Call the plumber about the leak"
        note.pinned = true
        phone.context.insert(note)
        try await phone.context.save()
        try await backend.eventually(laptop, "the edit never arrived") {
            try laptop.note(note.id)?.text == "Call the plumber about the leak"
        }
        try check(try laptop.note(note.id)?.pinned == true, "only part of the edit arrived")
    }

    static let deletionsTakeChildren = SyncScenario("Deleting a notebook deletes its notes on another device") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        let notebook = ScenarioNotebook(title: "Old", notes: [ScenarioNote(text: "A"), ScenarioNote(text: "B")])
        phone.context.insert(notebook)
        try await phone.context.save()
        try await backend.eventually(laptop, "the notebook never arrived") {
            try laptop.context.fetch(ScenarioNote.self).count == 2
        }

        phone.context.delete(notebook)
        try await phone.context.save()
        try await backend.eventually(laptop, "the deletion never arrived") {
            try laptop.notebook(notebook.id) == nil && laptop.context.fetch(ScenarioNote.self).isEmpty
        }
    }

    static let separateEditsMerge = SyncScenario("Edits to different properties on two devices both survive") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        var note = ScenarioNote(text: "Draft")
        phone.context.insert(note)
        try await phone.context.save()
        try await backend.eventually(laptop, "the note never arrived") { try laptop.note(note.id) != nil }

        note.text = "Final"
        phone.context.insert(note)
        var other = try laptop.note(note.id)!
        other.pinned = true
        laptop.context.insert(other)

        try await phone.context.save()
        try await laptop.context.save()   // conflicts, merges and sends the merge
        for device in [phone, laptop] {
            try await backend.eventually(device, "the merge never arrived") {
                let merged = try device.note(note.id)
                return merged?.text == "Final" && merged?.pinned == true
            }
        }
    }

    static let laterEditWins = SyncScenario("The later edit to the same property wins") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        var note = ScenarioNote(text: "Lunch at noon")
        phone.context.insert(note)
        try await phone.context.save()
        try await backend.eventually(laptop, "the note never arrived") { try laptop.note(note.id) != nil }

        note.text = "Lunch at one"
        phone.context.insert(note)
        try phone.commit()   // saved here, not sent yet
        try await Task.sleep(for: .milliseconds(20))
        var other = try laptop.note(note.id)!
        other.text = "Lunch at two"
        laptop.context.insert(other)
        try laptop.commit()   // the later edit

        try await laptop.context.save()
        try await phone.context.save()   // the older edit reaches the server last, and loses
        for device in [phone, laptop] {
            try await backend.eventually(device, "the devices never agreed on the later edit") {
                try device.note(note.id)?.text == "Lunch at two"
            }
        }
    }

    static let childrenFromTwoDevices = SyncScenario("Notes added to a notebook on two devices both arrive") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        var notebook = ScenarioNotebook(title: "Trip", notes: [ScenarioNote(text: "Tickets", position: 0)])
        phone.context.insert(notebook)
        try await phone.context.save()
        try await backend.eventually(laptop, "the notebook never arrived") { try laptop.notebook(notebook.id) != nil }

        var other = try laptop.notebook(notebook.id)!
        notebook.notes.append(ScenarioNote(text: "Hotel", position: 1))
        phone.context.insert(notebook)
        other.notes.append(ScenarioNote(text: "Car", position: 2))
        laptop.context.insert(other)
        try await phone.context.save()
        try await laptop.context.save()

        for device in [phone, laptop] {
            try await backend.eventually(device, "a device is missing a note") {
                try device.notebook(notebook.id)?.notes.map(\.text) == ["Tickets", "Hotel", "Car"]
            }
        }
    }

    static let linksArrive = SyncScenario("Many-to-many links arrive on another device") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        let work = ScenarioTag(name: "work")
        let urgent = ScenarioTag(name: "urgent")
        var notebook = ScenarioNotebook(title: "Projects", tags: [work, urgent])
        phone.context.insert(notebook)
        try await phone.context.save()
        try await backend.eventually(laptop, "the links never arrived") {
            Set(try laptop.notebook(notebook.id)?.tags.map(\.name) ?? []) == ["work", "urgent"]
        }
        let tags = try laptop.context.fetch(ScenarioTag.self)
        try check(tags.allSatisfy { $0.notebookIDs == [notebook.id] }, "the other side of the link differs")

        notebook.tags = [work]
        phone.context.insert(notebook)
        try await phone.context.save()
        try await backend.eventually(laptop, "the removed link never left") {
            try laptop.notebook(notebook.id)?.tags.map(\.name) == ["work"]
        }
    }

    static let attachmentsArrive = SyncScenario("An attachment arrives on another device") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let note = ScenarioNote(text: "Scan", attachment: bytes)
        phone.context.insert(note)
        try await phone.context.save()
        try await backend.eventually(laptop, "the attachment never arrived") {
            try laptop.note(note.id)?.attachment == bytes
        }
    }

    static let manyRecordsArrive = SyncScenario("Five hundred notes arrive across several batches") { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        let notebook = ScenarioNotebook(
            title: "Archive", notes: (0..<500).map { ScenarioNote(text: "Note \($0)", position: $0) }
        )
        phone.context.insert(notebook)
        try await phone.context.save()
        try check(phone.context.status == .saved, "the sending device shows \(phone.context.status)")
        try await backend.eventually(laptop, "not every note arrived") {
            try laptop.context.fetch(ScenarioNote.self).count == 500
        }
        try check(try laptop.notebook(notebook.id)?.notes.last?.text == "Note 499", "the notes arrived out of order")
    }

    static let offlineEditsSend = SyncScenario("Edits made offline are sent once back online", needsOffline: true) { backend, zone in
        let (phone, laptop) = try backend.pair(zone)
        backend.setOnline(false)
        let note = ScenarioNote(text: "Written on a plane")
        phone.context.insert(note)
        try await phone.context.save()
        try check(phone.context.status == .offline, "the device shows \(phone.context.status), not offline")

        backend.setOnline(true)
        try await phone.context.refresh()
        try check(phone.context.status == .saved, "the device shows \(phone.context.status) after reconnecting")
        try await backend.eventually(laptop, "the offline edit never arrived") { try laptop.note(note.id) != nil }
    }
}
