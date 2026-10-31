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
        context.autosave = .after(.milliseconds(50))
        var todo = ToDo(title: "First")
        context.insert(todo)
        try await Task.sleep(for: .milliseconds(20))
        // Another edit before the pause ends starts it again.
        todo.title = "Second"
        context.insert(todo)
        try await Task.sleep(for: .milliseconds(30))
        #expect(try stored(todo) == nil)
        for _ in 0..<50 where context.hasChanges {
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
