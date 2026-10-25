import Foundation
@testable import SwiftRecords
import Testing

@MainActor
@Suite struct SettingsTests {
    let container = try! RecordContainer(for: [ToDo.self], inMemory: true)
    var context: RecordContext { container.mainContext }

    @Test func eachKeyHasItsOwnZone() throws {
        #expect(Zone.settings("Favorite").name == "_settings.favorite")
        #expect(Zone.settings("favorite") != Zone.settings("theme"))
        #expect(Zone.settingsKey(for: "ToDo") == "todo")
        #expect(Zone.settingsKey(for: "Outer.Inner") == "outer_inner")
        #expect(Zone.settingsKey(for: "1st") == "s1st")
        #expect(throws: RecordsError.self) { try Zone(String("_settings.favorite")) }
    }

    @Test func storedNamesRoundTrip() throws {
        let zones: [Zone] = [.settings("favorite"), .default, .localOnly, "drafts"]
        let decoded = try JSONDecoder().decode([Zone].self, from: JSONEncoder().encode(zones))
        #expect(decoded == zones)
        #expect(Zone(stored: "_settings.favorite") == .settings("favorite"))
        #expect(Zone(stored: "_settings.") == nil)
        #expect(Zone(stored: "_other") == nil)
    }

    @Test func theLowestIDWins() {
        let first = ToDo(title: "First")
        let second = ToDo(title: "Second")
        #expect([second, first].setting?.title == "First")
        #expect([ToDo]().setting == nil)
    }

    @Test func storingCollapsesDuplicates() throws {
        context.autosaveEnabled = false
        let zone = Zone.settings("todo")
        let first = ToDo(title: "First")
        let second = ToDo(title: "Second")
        context.insert(first, in: zone)
        context.insert(second, in: zone)
        try context.save()
        let current = try container.storage(for: zone).fetch(ToDo.self)
        var edited = try #require(current.setting)
        edited.title = "Edited"
        context.storeSetting(edited, replacing: current, in: zone)
        try context.save()
        #expect(try container.storage(for: zone).fetch(ToDo.self).map(\.title) == ["Edited"])
        // An unchanged value writes nothing.
        context.storeSetting(edited, replacing: [edited], in: zone)
        #expect(!context.hasChanges)
        // Settings stay out of the context's own zone.
        #expect(try context.fetch(ToDo.self).isEmpty)
    }
}
