import Foundation
@testable import SwiftRecords
import Testing

@Record
struct Playlist {
    var id = UUID.ordered()
    var title = ""
    @Reference(to: \Track.playlist, sort: \.position) var tracks: [Track] = []
    @Reference(to: \Cover.playlist) var cover: Cover? = nil
    @Reference(to: Genre.self) var genres: [Genre] = []
    @Reference(to: Artist.self, sort: [SortDescriptor(\Artist.name)]) var artists: [Artist] = []
}

@Record
struct Track {
    var id = UUID.ordered()
    var name = ""
    var position = 0
    @Reference(from: Playlist.self, action: .deleteSelf) var playlist: Playlist.ID?
}

@Record
struct Cover {
    var id = UUID.ordered()
    var caption = ""
    @Reference(from: Playlist.self, action: .deleteSelf) var playlist: Playlist.ID?
}

@Record
struct Genre {
    var id = UUID.ordered()
    var name = ""
    @Reference(to: \Playlist.genres) var playlistIDs: Set<Playlist.ID>
}

@Record
struct Artist {
    var id = UUID.ordered()
    var name = ""
}

@Suite struct RelationshipOrderTests {
    let container = try! RecordContainer(for: [Playlist.self], inMemory: true)

    private func playlist(_ id: Playlist.ID) throws -> Playlist {
        try #require(try container.fetch(Playlist.self, id: id))
    }

    // MARK: sort:

    @Test func childrenComeInSortOrder() throws {
        var playlist = Playlist(tracks: [Track(name: "B", position: 2), Track(name: "A", position: 1), Track(name: "C", position: 3)])
        try container.save(playlist)
        #expect(try self.playlist(playlist.id).tracks.map(\.name) == ["A", "B", "C"])

        // Reordering is a change to the children's own property.
        playlist.tracks[0].position = 0
        try container.save(playlist)
        #expect(try self.playlist(playlist.id).tracks.map(\.name) == ["B", "A", "C"])
    }

    @Test func linksComeInSortOrder() throws {
        let playlist = Playlist(artists: [Artist(name: "Zed"), Artist(name: "Amy"), Artist(name: "Max")])
        try container.save(playlist)
        #expect(try self.playlist(playlist.id).artists.map(\.name) == ["Amy", "Max", "Zed"])
    }

    @Test func linksWithoutSortComeInTheOrderTheyWereMade() throws {
        var playlist = Playlist(genres: [Genre(name: "Rock")])
        try container.save(playlist)
        playlist.genres.insert(Genre(name: "Jazz"), at: 0)
        try container.save(playlist)
        // The array's order isn't stored: the newer link comes last.
        #expect(try self.playlist(playlist.id).genres.map(\.name) == ["Rock", "Jazz"])
    }

    // MARK: One-to-one

    @Test func aSingleChildLoadsAndGoesWithItsParent() throws {
        var playlist = Playlist(cover: Cover(caption: "Front"))
        try container.save(playlist)
        #expect(try self.playlist(playlist.id).cover?.caption == "Front")

        playlist.cover = nil
        try container.save(playlist)
        #expect(try self.playlist(playlist.id).cover == nil)
        #expect(try container.fetch(Cover.self).isEmpty)
    }

    @Test func theOtherSideOfAManyToManyListsItsOwners() throws {
        let rock = Genre(name: "Rock")
        let first = Playlist(title: "First", genres: [rock])
        let second = Playlist(title: "Second", genres: [rock])
        try container.save([first, second])
        #expect(try container.fetch(Genre.self, id: rock.id)?.playlistIDs == [first.id, second.id])

        try container.delete(first)
        #expect(try container.fetch(Genre.self, id: rock.id)?.playlistIDs == [second.id])
    }

    // MARK: IDs

    @Test func orderedIDsAreVersion7AndIncrease() {
        let ids = (0..<1000).map { _ in UUID.ordered() }
        #expect(ids.allSatisfy { $0.uuid.6 >> 4 == 7 && $0.uuid.8 >> 6 == 0b10 })
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0.uuidString < $1.uuidString })
    }

    @Test func nameBasedIDsMatchRFC9562() {
        // The RFC's version 5 example: "www.example.com" in the DNS namespace.
        let dns = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        #expect(UUID(named: "www.example.com", in: dns) == UUID(uuidString: "2ED6657D-E927-568B-95E1-2665A8AEA6A2"))
    }

    @Test func aLinkHasTheSameIDOnEveryDevice() {
        let from = UUID.ordered(), to = UUID.ordered()
        #expect(_RecordLink.id(relation: "Playlist.genres", from: from, to: to) == _RecordLink.id(relation: "Playlist.genres", from: from, to: to))
        #expect(_RecordLink.id(relation: "Playlist.genres", from: from, to: to) != _RecordLink.id(relation: "Playlist.genres", from: to, to: from))
    }
}
