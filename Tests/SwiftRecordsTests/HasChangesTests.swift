import Foundation
@testable import SwiftRecords
import Testing

@Record
struct Draft {
    var id = UUID()
    var title = ""
    var tags: Set<String> = []
    var steps: [DraftStep] = []
    @Asset(fileExtension: "png") var image: Data?
    @Timestamp var modified: Date?
}

@Record
struct DraftStep {
    var id = UUID()
    var text = ""
    @Reference(from: \Draft.steps) var drafts: Set<Draft.ID>
}

@MainActor
@Suite struct HasChangesTests {
    let container = try! RecordContainer(for: [Draft.self], inMemory: true)
    var context: RecordContext {
        container.mainContext
    }

    init() {
        container.mainContext.autosaveEnabled = false
    }

    @Test func followsEditsAndSaves() throws {
        var draft = Draft(title: "Soup")
        #expect(context.hasChanges(draft))

        context.save(draft)
        #expect(!context.hasChanges(draft))
        try context.save()
        #expect(!context.hasChanges(draft))

        draft.title = "Stew"
        #expect(context.hasChanges(draft))
        draft.title = "Soup"
        #expect(!context.hasChanges(draft))

        context.delete(draft)
        #expect(context.hasChanges(draft))
    }

    @Test func relatedRecordsCount() throws {
        var draft = Draft(title: "Soup", steps: [DraftStep(text: "Boil")])
        context.save(draft)
        try context.save()

        draft.steps[0].text = "Simmer"
        #expect(context.hasChanges(draft))
        draft.steps[0].text = "Boil"
        draft.steps.append(DraftStep(text: "Serve"))
        #expect(context.hasChanges(draft))
    }

    @Test func ignoresWhatTheContainerSets() throws {
        let step = DraftStep(text: "Boil")
        let draft = Draft(title: "Soup", tags: ["a", "b", "c"], steps: [step])
        context.save(draft)
        try context.save()

        // The stored copy now has a modified date, and its step an inverse, that this copy lacks.
        let stored = try #require(try context.fetch(Draft.self, id: draft.id))
        #expect(stored.modified != nil)
        #expect(!context.hasChanges(draft))

        // Another draft sharing the step changes only its inverse.
        context.save(Draft(title: "Broth", steps: [step]))
        try context.save()
        #expect(!context.hasChanges(step))
        #expect(!context.hasChanges(stored))
    }

    @Test func comparesAssetsByFile() throws {
        var draft = Draft(title: "Soup")
        context.save(draft)
        try context.save()

        draft.image = Data([1, 2, 3])
        #expect(context.hasChanges(draft))
        context.save(draft)
        try context.save()
        #expect(!context.hasChanges(draft))

        let stored = try #require(try context.fetch(Draft.self, id: draft.id))
        #expect(!context.hasChanges(stored))
        var replaced = stored
        replaced.image = Data([1, 2, 3])
        #expect(context.hasChanges(replaced))
    }

    @Test func backgroundContextsCompareWithTheStore() async throws {
        let draft = Draft(title: "Soup")
        try await container.performBackgroundTask { context in
            #expect(try context.hasChanges(draft))
            try context.save(draft)
            #expect(try !context.hasChanges(draft))
        }
    }
}
