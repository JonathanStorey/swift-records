import Foundation
@testable import SwiftRecords
import Testing

@Record
struct SyncNote {
    var id = UUID.ordered()
    var text = ""
    @Timestamp(.modified) var edited: Date?
}

@MainActor
@Suite struct EditTimeTests {
    let server = TestServer()

    private func device(_ types: [any Record.Type]) throws -> RecordContainer {
        let provider = TestProvider(server: server)
        let container = try RecordContainer(
            for: types, inMemory: true, syncProvider: provider
        )
        return container
    }

    /// Commits without sending, as the synchronous `save()` does.
    private func commit(_ container: RecordContainer) throws {
        try container.mainContext.save()
    }

    @Test func recordsCarryOnlyTheirProperties() async throws {
        let phone = try device([SyncRecipe.self])
        let recipe = SyncRecipe(title: "Soup")
        phone.mainContext.insert(recipe)
        try await phone.mainContext.save()
        #expect(!server.has("SyncRecipe", recipe.id, "_position"))
        #expect(!server.has("SyncRecipe", recipe.id, "_modified"))
    }

    @Test func aModifiedTimestampDatesEachCopyInAClash() async throws {
        let phone = try device([SyncNote.self])
        let tablet = try device([SyncNote.self])
        var note = SyncNote(text: "Draft")
        phone.mainContext.insert(note)
        try await phone.mainContext.save()
        try await tablet.mainContext.refresh()

        note.text = "Tablet"
        tablet.mainContext.insert(note)
        try commit(tablet)   // committed first, sent last
        try await Task.sleep(for: .milliseconds(20))
        note.text = "Phone"
        phone.mainContext.insert(note)
        try await phone.mainContext.save()

        // The phone's edit is later by its timestamp, though the tablet edited after the server's date.
        try await tablet.mainContext.save()
        #expect(try tablet.mainContext.fetch(SyncNote.self).map(\.text) == ["Phone"])
    }
}
