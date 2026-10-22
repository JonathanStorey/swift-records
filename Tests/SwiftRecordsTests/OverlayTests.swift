import Foundation
@testable import SwiftRecords
import Testing

/// What `@Records` shows before the context saves.
@MainActor
@Suite struct OverlayTests {
    let container = try! RecordContainer(for: [Draft.self], inMemory: true)
    var context: RecordContext {
        container.mainContext
    }

    init() {
        container.mainContext.autosaveEnabled = false
    }

    private func stored() throws -> [Draft] {
        try context.storage(for: nil).fetch(Draft.self, where: nil)
    }

    private func shown(_ predicate: Predicate<Draft>? = nil, source: ObjectIdentifier? = nil) throws -> [Draft] {
        let stored = try context.storage(for: nil).fetch(Draft.self, where: predicate)
        return context.overlay(stored, in: nil, source: source) { (try? predicate?.evaluate($0)) ?? true }
    }

    @Test func appendsShowBeforeSaving() throws {
        let soup = Draft(title: "Soup")
        context.save(soup)
        try context.save()

        let stew = Draft(title: "Stew")
        try context.append(stew)
        #expect(try stored().map(\.title) == ["Soup"])
        #expect(try shown().map(\.title) == ["Soup", "Stew"])
    }

    @Test func editsAndDeletesShowBeforeSaving() throws {
        var soup = Draft(title: "Soup")
        let stew = Draft(title: "Stew")
        context.save(soup)
        context.save(stew)
        try context.save()

        soup.title = "Broth"
        context.save(soup)
        context.delete(stew)
        #expect(try shown().map(\.title) == ["Broth"])

        context.rollback()
        #expect(try shown().map(\.title) == ["Soup", "Stew"])
    }

    @Test func filtersApplyToUnsavedRecords() throws {
        var soup = Draft(title: "Soup")
        context.save(soup)
        try context.save()

        let predicate = #Predicate<Draft> { $0.title.starts(with: "S") }
        context.save(Draft(title: "Salad"))
        context.save(Draft(title: "Bread"))
        soup.title = "Broth"
        context.save(soup)
        #expect(try shown(predicate).map(\.title) == ["Salad"])
    }

    @Test func singleRecordsShowBeforeSaving() throws {
        var soup = Draft(title: "Soup")
        context.save(soup)
        try context.save()
        let fetched = try context.storage(for: nil).fetch(Draft.self, id: soup.id)

        soup.title = "Broth"
        context.save(soup)
        #expect(context.overlay(fetched, id: soup.id, in: nil)?.title == "Broth")
        context.delete(soup)
        #expect(context.overlay(fetched, id: soup.id, in: nil) == nil)
    }

    @Test func otherZonesStayOut() throws {
        context.zone = "pantry"
        try context.append(Draft(title: "Flour"))
        context.zone = nil
        #expect(try shown().isEmpty)
    }

    @Test func aViewsOwnOrderApplies() throws {
        let soup = Draft(title: "Soup")
        let stew = Draft(title: "Stew")
        context.save(soup)
        context.save(stew)
        try context.save()

        let view = ObjectIdentifier(container)
        context.apply([stew, soup], replacing: [soup, stew], source: view)
        #expect(try shown(source: view).map(\.title) == ["Stew", "Soup"])
        #expect(try shown().map(\.title) == ["Soup", "Stew"])
    }

    @Test func changesFromOthersAreTracked() throws {
        let view = ObjectIdentifier(container)
        let start = context.sequence
        context.apply([Draft(title: "Soup")], replacing: [], source: view)
        #expect(!context.hasPendingChanges(after: start, excluding: view))
        context.save(Draft(title: "Stew"))
        #expect(context.hasPendingChanges(after: start, excluding: view))
        #expect(!context.hasPendingChanges(after: context.sequence, excluding: view))
    }

    @Test func changesShowWhileSaving() async throws {
        try context.append(Draft(title: "Soup"))
        var done = false
        let saving = Task {
            try await context.save()
            done = true
        }
        // However the save interleaves, the record shows once: pending, committing, then stored.
        while !done {
            #expect(try shown().map(\.title) == ["Soup"])
            await Task.yield()
        }
        try await saving.value
        #expect(try shown().map(\.title) == ["Soup"])
    }
}
