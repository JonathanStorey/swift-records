import Foundation
import Testing
@testable import SwiftRecords

private struct Album: Codable, Identifiable {
    var id = UUID()
    var name = ""
    @References<Photo>(inverse: \Photo.albums) var photos: [Photo.ID] = []
    @References<Photo> var covers: [Photo.ID] = []
}

private struct Photo: Codable, Identifiable {
    var id = UUID()
    var caption = ""
    @References<Album>(inverse: \Album.photos) var albums: [Album.ID] = []
}

/// `fetch(_:)` with a reference list returns its targets through the context, in list order.
@Suite struct RecordContextReferencesFetchTests {
    private let container = RecordContainer.inMemory(Album.self, Photo.self)

    /// Saves three photos, then an album listing them in both lists, in an order unlike the
    /// order they were saved in.
    private func savedAlbum() throws -> (Album, [Photo]) {
        let photos = [Photo(caption: "a"), Photo(caption: "b"), Photo(caption: "c")]
        for photo in photos { try container.save(our: photo, zone: "Records") }
        let order = [photos[2].id, photos[0].id, photos[1].id]
        let album = Album(name: "Trip", photos: order, covers: order)
        try container.save(our: album, zone: "Records")
        return (album, photos)
    }

    @Test func aFieldListReturnsItsTargetsInOrder() throws {
        let (album, _) = try savedAlbum()
        let context = RecordContext(container)
        let fetched = try #require(context.record(Album.self, id: album.id))
        #expect(context.fetch(fetched.$covers).map(\.caption) == ["c", "a", "b"])
    }

    @Test func aRelationshipListReturnsItsTargetsInOrder() throws {
        let (album, _) = try savedAlbum()
        let context = RecordContext(container)
        let fetched = try #require(context.record(Album.self, id: album.id))
        #expect(context.fetch(fetched.$photos).map(\.caption) == ["c", "a", "b"])
    }

    @Test func theOtherSideOfARelationshipReadsTheSame() throws {
        let (album, photos) = try savedAlbum()
        let context = RecordContext(container)
        let photo = try #require(context.record(Photo.self, id: photos[0].id))
        #expect(context.fetch(photo.$albums).map(\.id) == [album.id])
    }

    @Test func anUnsavedEditOfATargetIsReturnedAsEdited() throws {
        let (album, photos) = try savedAlbum()
        let context = RecordContext(container)
        var edited = photos[0]
        edited.caption = "edited"
        context.insert(edited)
        let fetched = try #require(context.record(Album.self, id: album.id))
        #expect(context.fetch(fetched.$covers).map(\.caption) == ["c", "edited", "b"])
    }

    @Test func aDeletedTargetIsLeftOut() throws {
        let (album, photos) = try savedAlbum()
        let context = RecordContext(container)
        let fetched = try #require(context.record(Album.self, id: album.id))
        context.delete(photos[2])
        #expect(context.fetch(fetched.$covers).map(\.caption) == ["a", "b"])
    }

    @Test func aTargetThatHasNotArrivedIsLeftOut() throws {
        let photo = Photo(caption: "here")
        try container.save(our: photo, zone: "Records")
        let album = Album(name: "Partial", covers: [UUID(), photo.id])
        #expect(RecordContext(container).fetch(album.$covers).map(\.caption) == ["here"])
    }

    @Test func aChildInsertedIntoARelationshipListIsReturnedBeforeSaving() throws {
        let (album, _) = try savedAlbum()
        let context = RecordContext(container)
        context.insert(Photo(caption: "new"), into: album.id, at: \Album.photos)
        let fetched = try #require(context.record(Album.self, id: album.id))
        #expect(context.fetch(fetched.$photos).map(\.caption) == ["c", "a", "b", "new"])
    }

    @Test func anEmptyListReturnsNothing() {
        #expect(RecordContext(container).fetch(Album().$photos).isEmpty)
    }
}

/// `fetch(_:in:)` and `fetchCount(_:in:)` read another zone than the context's own, with the
/// context's edits in that zone.
@Suite struct RecordContextZoneFetchTests {
    private let container = RecordContainer.inMemory(Album.self, Photo.self)

    @Test func anotherZoneReturnsItsOwnRecordsAndEdits() throws {
        try container.save(our: Photo(caption: "home"), zone: "Records")
        let away = Photo(caption: "away")
        try container.save(our: away, zone: "Shared")
        let context = RecordContext(container)
        context.zone = "Shared"
        var edited = away
        edited.caption = "edited"
        context.insert(edited)
        context.insert(Photo(caption: "new"))
        context.zone = "Records"

        let descriptor = RecordDescriptor<Photo>(sortBy: [SortDescriptor(\.caption)])
        #expect(try context.fetch(descriptor, in: "Shared").map(\.caption) == ["edited", "new"])
        #expect(try context.fetchCount(descriptor, in: "Shared") == 2)
        #expect(try context.fetch(descriptor).map(\.caption) == ["home"], "The context's own zone is unchanged.")
        #expect(try context.fetchCount(descriptor) == 1)
    }

    @Test func aListReadsInItsHoldersZone() throws {
        let photos = [Photo(caption: "a"), Photo(caption: "b")]
        for photo in photos { try container.save(our: photo, zone: "Shared") }
        let ids = photos.map(\.id)
        try container.save(our: Album(name: "Away", photos: ids, covers: ids), zone: "Shared")
        let context = RecordContext(container)
        let album = try #require(try context.fetch(RecordDescriptor<Album>(), in: "Shared").first)
        #expect(context.fetch(album.$covers).map(\.caption) == ["a", "b"], "A field list reads in the album's zone, not the context's.")
        #expect(context.fetch(album.$photos).map(\.caption) == ["a", "b"], "So does a relationship list.")
    }
}
