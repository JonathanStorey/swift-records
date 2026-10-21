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
    @Reference(from: \Draft.steps) var drafts: [Draft.ID] = []
}

@MainActor
@Suite struct HasChangesTests {
    let container = try! RecordContainer(for: [Draft.self], zone: .inMemory)
    var context: RecordsContext {
        container.mainContext
    }

    init() {
        container.mainContext.autosaveEnabled = false
    }

    @Test func followsEditsAndSaves() throws {
        var draft = Draft(title: "Soup")
        #expect(draft.hasChanges(in: context))

        context.save(draft)
        #expect(!draft.hasChanges(in: context))
        try context.save()
        #expect(!draft.hasChanges(in: context))

        draft.title = "Stew"
        #expect(draft.hasChanges(in: context))
        draft.title = "Soup"
        #expect(!draft.hasChanges(in: context))

        context.delete(draft)
        #expect(draft.hasChanges(in: context))
    }

    @Test func relatedRecordsCount() throws {
        var draft = Draft(title: "Soup", steps: [DraftStep(text: "Boil")])
        context.save(draft)
        try context.save()

        draft.steps[0].text = "Simmer"
        #expect(draft.hasChanges(in: context))
        draft.steps[0].text = "Boil"
        draft.steps.append(DraftStep(text: "Serve"))
        #expect(draft.hasChanges(in: context))
    }

    @Test func ignoresWhatTheContainerSets() throws {
        let step = DraftStep(text: "Boil")
        let draft = Draft(title: "Soup", tags: ["a", "b", "c"], steps: [step])
        context.save(draft)
        try context.save()

        // The stored copy now has a modified date, and its step an inverse, that this copy lacks.
        let stored = try #require(try context.fetch(Draft.self, id: draft.id))
        #expect(stored.modified != nil)
        #expect(!draft.hasChanges(in: context))

        // Another draft sharing the step changes only its inverse.
        context.save(Draft(title: "Broth", steps: [step]))
        try context.save()
        #expect(!step.hasChanges(in: context))
        #expect(!stored.hasChanges(in: context))
    }

    @Test func comparesAssetsByFile() throws {
        var draft = Draft(title: "Soup")
        context.save(draft)
        try context.save()

        draft.image = Data([1, 2, 3])
        #expect(draft.hasChanges(in: context))
        context.save(draft)
        try context.save()
        #expect(!draft.hasChanges(in: context))

        let stored = try #require(try context.fetch(Draft.self, id: draft.id))
        #expect(!stored.hasChanges(in: context))
        var replaced = stored
        replaced.image = Data([1, 2, 3])
        #expect(replaced.hasChanges(in: context))
    }

    @Test func backgroundContextsCompareWithTheStore() async throws {
        let draft = Draft(title: "Soup")
        try await container.performBackgroundTask { context in
            #expect(try draft.hasChanges(in: context))
            try context.save(draft)
            #expect(try !draft.hasChanges(in: context))
        }
    }
}
