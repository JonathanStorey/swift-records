import Foundation
import Testing
@testable import SwiftRecords

@Suite struct RecordContextTests {
    @MainActor @Test func theMainContextIsMadeOnceAndKept() {
        let container = RecordContainer()
        #expect(container.mainContext === container.mainContext)
    }

    @MainActor @Test func theMainContextBelongsToItsContainer() {
        let container = RecordContainer()
        #expect(container.mainContext.container === container)
    }

    @MainActor @Test func eachContainerHasItsOwnMainContext() {
        #expect(RecordContainer().mainContext !== RecordContainer().mainContext)
    }

    @Test func anotherContextIsSeparateFromTheMainOne() async {
        let container = RecordContainer()
        let context = RecordContext(container)
        let main = await MainActor.run { ObjectIdentifier(container.mainContext) }
        #expect(ObjectIdentifier(context) != main)
        #expect(context.container === container)
    }
}

private struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var body = ""
}

private struct Page: Codable, Identifiable, Equatable {
    var id: String
    var title = ""
}

/// `insert(_:)` opens a draft and writes nothing.
@Suite struct RecordContextInsertTests {
    private let container = RecordContainer.inMemory(Note.self, Page.self)

    private func draft<R: Codable & Identifiable>(_ record: R, in context: RecordContext, zone: Zone = "Records") throws -> Draft<R>? where R.ID: Encodable {
        let name = try RecordContainer.recordName(for: record.id, type: RecordContainer.recordType(of: R.self))
        return context.drafts[RecordContainer.RowID(name: name, zone: zone)] as? Draft<R>
    }

    @Test func aNewRecordOpensADraftWithNoBase() throws {
        let context = RecordContext(container)
        let note = Note(title: "Groceries")
        context.insert(note)

        let draft = try #require(try draft(note, in: context))
        #expect(draft.ours == note)
        #expect(draft.base == nil)
        #expect(try container.row(id: note.id) == nil, "Nothing is written before a save.")
    }

    @Test func aSavedRecordTakesItsSavedValueAsTheBase() throws {
        let saved = Note(title: "Saved")
        try container.save(our: saved, zone: "Records")
        let context = RecordContext(container)
        context.insert(Note(id: saved.id, title: "Edited"))

        let draft = try #require(try draft(saved, in: context))
        #expect(draft.base == saved)
        #expect(draft.ours.title == "Edited")
    }

    @Test func insertingAgainKeepsTheDraftAndReplacesTheEdit() throws {
        let context = RecordContext(container)
        let note = Note(title: "First")
        context.insert(note)
        let first = try #require(try draft(note, in: context))
        context.insert(Note(id: note.id, title: "Second"))

        let second = try #require(try draft(note, in: context))
        #expect(first === second, "A view watching the draft keeps watching it.")
        #expect(second.ours.title == "Second")
        #expect(second.base == nil)
    }

    @Test func theZoneDecidesTheRow() throws {
        let note = Note(title: "Saved")
        try container.save(our: note, zone: "Records")
        let context = RecordContext(container)
        context.zone = "Elsewhere"
        context.insert(Note(id: note.id, title: "Edited"))

        let draft = try #require(try draft(note, in: context, zone: "Elsewhere"))
        #expect(draft.base == nil, "The copy in Records is not this row.")
        #expect(try self.draft(note, in: context) == nil)
    }

    @Test func aRecordNamedByItsTypeAndIdFindsItsRow() throws {
        let page = Page(id: "intro", title: "Saved")
        try container.save(our: page, zone: "Records")
        let context = RecordContext(container)
        context.insert(Page(id: "intro", title: "Edited"))
        #expect(try draft(page, in: context)?.base == page)
    }
}
