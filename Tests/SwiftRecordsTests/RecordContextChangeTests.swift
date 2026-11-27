import Foundation
import Observation
import Testing
@testable import SwiftRecords

private struct Memo: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var body = ""
}

private struct Album: Codable, Identifiable {
    var id = UUID()
    var name = ""
    @References<Photo>(inverse: \Photo.albums) var photos: [Photo.ID] = []
}

private struct Photo: Codable, Identifiable {
    var id = UUID()
    @References<Album>(inverse: \Album.photos) var albums: [Album.ID] = []
}

/// `apply(_:)` brings a context's drafts up to date with what its container committed.
@Suite struct RecordContextChangeTests {
    private let container = RecordContainer.inMemory(Memo.self, Album.self, Photo.self)

    private func rowID(_ memo: Memo) throws -> RecordContainer.RowID {
        try RecordContainer.RowID(name: RecordContainer.recordName(for: memo.id, type: "Memo"), zone: "Records")
    }

    private func transaction(_ changes: RecordTransaction.Change..., author: String? = nil) -> RecordTransaction {
        RecordTransaction(id: 1, author: author, timestamp: Date(), changes: changes)
    }

    /// A context with `memo` saved and its draft open, edited to `edit` when given.
    private func open(_ memo: Memo, editedTo edit: Memo? = nil) throws -> RecordContext {
        try container.save(our: memo, zone: "Records")
        let context = RecordContext(container)
        context.insert(edit ?? memo)
        return context
    }

    @Test func anUnchangedDraftTakesTheNewSavedValue() throws {
        let memo = Memo(title: "Old")
        let context = try open(memo)
        var theirs = memo
        theirs.title = "New"
        try container.save(our: theirs, zone: "Records")
        context.apply(transaction(.updated(try rowID(memo), type: "Memo")))

        #expect(context.record(Memo.self, id: memo.id) == theirs)
        #expect(!context.hasChanges)
    }

    @Test func anEditKeepsWhatTheUserChangedAndTakesTheRest() throws {
        let memo = Memo(title: "Old", body: "Old")
        var ours = memo, theirs = memo
        ours.body = "Mine"
        theirs.title = "Theirs"
        let context = try open(memo, editedTo: ours)
        try container.save(our: theirs, zone: "Records")
        context.apply(transaction(.updated(try rowID(memo), type: "Memo")))

        #expect(context.record(Memo.self, id: memo.id) == Memo(id: memo.id, title: "Theirs", body: "Mine"))
        #expect(context.drafts.draft(Memo.self, at: try rowID(memo))?.base == theirs, "The saved value is the new base.")
    }

    @Test func whereBothChangedTheSameFieldTheEditWins() throws {
        let memo = Memo(title: "Old")
        var ours = memo, theirs = memo
        ours.title = "Mine"
        theirs.title = "Theirs"
        let context = try open(memo, editedTo: ours)
        try container.save(our: theirs, zone: "Records")
        context.apply(transaction(.updated(try rowID(memo), type: "Memo")))

        #expect(context.record(Memo.self, id: memo.id)?.title == "Mine")
    }

    @Test func anUnchangedDraftOfARecordDeletedElsewhereIsDeleted() throws {
        let memo = Memo(title: "Gone")
        let context = try open(memo)
        try container.delete(our: memo, zone: "Records")
        context.apply(transaction(.deleted(try rowID(memo), type: "Memo")))

        #expect(context.record(Memo.self, id: memo.id) == nil)
        #expect(!context.hasChanges, "Nothing is left to delete.")
    }

    @Test func anEditedDraftOfARecordDeletedElsewhereSavesAsNew() throws {
        let memo = Memo(title: "Old")
        var ours = memo
        ours.title = "Still typing"
        let context = try open(memo, editedTo: ours)
        try container.delete(our: memo, zone: "Records")
        context.apply(transaction(.deleted(try rowID(memo), type: "Memo")))

        #expect(context.record(Memo.self, id: memo.id) == ours)
        try context.save()
        #expect(RecordContext(container).record(Memo.self, id: memo.id) == ours)
    }

    @Test func aDeleteInTheContextStaysDeletedWhenTheRecordGoesElsewhereToo() throws {
        let memo = Memo(title: "Gone")
        let context = try open(memo)
        context.delete(memo)
        try container.delete(our: memo, zone: "Records")
        context.apply(transaction(.deleted(try rowID(memo), type: "Memo")))

        #expect(context.record(Memo.self, id: memo.id) == nil)
        #expect(!context.hasChanges)
    }

    @Test func aNewRecordIsUntouchedByAnotherRecordsChange() throws {
        let context = RecordContext(container)
        let new = Memo(title: "New")
        context.insert(new)
        let other = Memo(title: "Other")
        try container.save(our: other, zone: "Records")
        let before = context.revision
        context.apply(transaction(.inserted(try rowID(other), type: "Memo")))

        #expect(context.record(Memo.self, id: new.id) == new)
        #expect(context.revision == before + 1)
    }

    @Test func anotherProcessesTransactionRefreshesEveryDraft() throws {
        let memo = Memo(title: "Old")
        let context = try open(memo)
        var theirs = memo
        theirs.title = "From the widget"
        try container.save(our: theirs, zone: "Records")
        context.apply(transaction(author: RecordContainer.externalAuthor))

        #expect(context.record(Memo.self, id: memo.id) == theirs)
    }

    @Test func aRelationshipSavedElsewhereReachesTheOpenAlbum() async throws {
        let album = Album(name: "Trip")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        context.insert(album)
        let transactions = container.transactions()

        let other = RecordContext(container)
        let photo = Photo()
        other.insert(photo, into: album.id, at: \Album.photos)
        try other.save()
        var iterator = transactions.makeAsyncIterator()
        context.apply(try #require(await iterator.next()))

        #expect(context.record(Album.self, id: album.id)?.photos == [photo.id])
        #expect(!context.hasChanges)
    }

    @Test func aRelationshipSavedElsewhereReachesAnEditedAlbum() async throws {
        let album = Album(name: "Trip")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        context.insert(Album(id: album.id, name: "Road trip"))
        let transactions = container.transactions()

        let other = RecordContext(container)
        let photo = Photo()
        other.insert(photo, into: album.id, at: \Album.photos)
        try other.save()
        var iterator = transactions.makeAsyncIterator()
        context.apply(try #require(await iterator.next()))

        let merged = try #require(context.record(Album.self, id: album.id))
        #expect(merged.name == "Road trip")
        #expect(merged.photos == [photo.id])
    }

    @Test func anUntouchedRecordWithAnEmptyRelationshipListHasNoChanges() throws {
        let album = Album(name: "Trip")
        try container.save(our: album, zone: "Records")
        let context = RecordContext(container)
        context.insert(album)
        #expect(!context.hasChanges)
    }

    @Test func aFetchIsToldWhenTheContainerChanges() throws {
        let context = RecordContext(container)
        nonisolated(unsafe) var isChanged = false
        withObservationTracking {
            _ = try? context.fetch(RecordDescriptor<Memo>())
        } onChange: {
            isChanged = true
        }
        try container.save(our: Memo(), zone: "Records")
        context.apply(transaction())
        #expect(isChanged)
    }
}

/// The main context applies its container's transactions itself.
@MainActor @Suite struct RecordContextListenTests {
    /// Waits up to a second for `condition`, letting the main actor run the listening task.
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @Test func theMainContextFollowsAnotherContextsSave() async throws {
        let container = RecordContainer.inMemory(Memo.self)
        let memo = Memo(title: "Old")
        try container.save(our: memo, zone: "Records")
        let main = container.mainContext
        main.insert(memo)
        let revision = main.revision

        let other = RecordContext(container)
        other.insert(Memo(id: memo.id, title: "New"))
        try other.save()

        #expect(try await eventually { main.record(Memo.self, id: memo.id)?.title == "New" })
        #expect(main.revision > revision)
    }

    @Test func aReleasedContextStopsListening() async throws {
        let container = RecordContainer.inMemory(Memo.self)
        var context: RecordContext? = RecordContext(container)
        context?.listen()
        #expect(container.locked { container.listeners.count } == 1)
        context = nil
        #expect(try await eventually { container.locked { container.listeners.isEmpty } })
    }
}
