import Foundation
@testable import SwiftRecords
import Testing

/// The context saves on its own once edits pause, when asked to.
@MainActor
@Suite struct AutosaveTests {
    let container = try! RecordContainer(for: [ToDo.self], inMemory: true)
    var context: RecordContext { container.mainContext }

    private func stored(_ todo: ToDo) throws -> ToDo? {
        try container.fetch(ToDo.self, id: todo.id)
    }

    @Test func byDefaultItSavesOnlyWhenInactive() async throws {
        #expect(context.autosave == .whenInactive)
        let todo = ToDo(title: "Kept")
        context.insert(todo)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try stored(todo) == nil)
        #expect(context.hasChanges)
    }

    @Test func itSavesOnceEditsPause() async throws {
        context.autosave = .after(.milliseconds(300))
        var todo = ToDo(title: "First")
        context.insert(todo)
        try await Task.sleep(for: .milliseconds(100))
        // Another edit before the pause ends starts it again.
        todo.title = "Second"
        context.insert(todo)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try stored(todo) == nil)
        // The save runs off the main actor, so wait for it to land rather than for pending changes to clear.
        for _ in 0..<100 where try stored(todo)?.title != "Second" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try stored(todo)?.title == "Second")
        #expect(!context.hasChanges)
    }

    @Test func turningItOffCancelsAPendingSave() async throws {
        context.autosave = .after(.milliseconds(50))
        let todo = ToDo(title: "Kept")
        context.insert(todo)
        context.autosave = .whenInactive
        try await Task.sleep(for: .milliseconds(150))
        #expect(try stored(todo) == nil)
    }

    @Test func theDefaultSavesWhenTheAppBecomesInactive() throws {
        let todo = ToDo(title: "Kept")
        context.insert(todo)
        context.willResignActive()
        #expect(try stored(todo)?.title == "Kept")
    }

    @Test func noAutosaveLeavesEverySaveToTheApp() throws {
        context.autosave = nil
        let todo = ToDo(title: "Kept")
        context.insert(todo)
        context.willResignActive()
        #expect(try stored(todo) == nil)
        #expect(context.hasChanges)
    }
}
