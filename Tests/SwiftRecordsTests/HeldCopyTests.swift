import Foundation
import Identification
@testable import SwiftRecords
import Testing

@Record
struct Disc {
    var id = UUID.timestamp
    var title = ""
    var plays = 0
    @Reference(to: \Song.disc, sort: \.position) var songs: [Song] = []
}

@Record
struct Song {
    var id = UUID.timestamp
    var title = ""
    var position = 0
    var plays = 0
    @Reference(from: Disc.self, action: .deleteSelf) var disc: Disc.ID?
}

@Record
struct Mix {
    var id = UUID.timestamp
    var title = ""
    @Reference(to: Song.self) var songs: [Song] = []
}

/// A record holds copies of its children and linked records. Saving it writes only the copies it changed,
/// so an older copy never undoes a change made to the record itself, and a copy saved through a link never
/// clears the pointers it doesn't know.
@MainActor
@Suite struct HeldCopyTests {
    let context = try! RecordContainer(for: [Disc.self, Mix.self], location: .inMemory).mainContext

    private func disc() throws -> Disc {
        try #require(try context.fetch(Disc.self).first)
    }

    private func song(_ id: Song.ID) throws -> Song {
        try #require(try context.record(Song.self, for: id))
    }

    /// A saved disc with two songs.
    private func saved() throws -> Disc {
        var disc = Disc(title: "Side A")
        disc.songs = [Song(title: "One", position: 1), Song(title: "Two", position: 2)]
        context.insert(disc)
        try context.save()
        return try self.disc()
    }

    @Test func aParentSavedAfterItsChildKeepsTheChildsEdit() throws {
        var disc = try saved()
        var song = disc.songs[0]
        song.plays += 1
        context.insert(song)
        disc.plays += 1
        context.insert(disc)
        try context.save()
        #expect(try self.song(song.id).plays == 1)
        #expect(try self.disc().plays == 1)
    }

    @Test func aStaleParentSavedLaterKeepsTheChildsEdit() throws {
        var disc = try saved()
        var song = disc.songs[1]
        song.title = "Two (live)"
        context.insert(song)
        try context.save()

        disc.title = "Side B"
        context.insert(disc)
        try context.save()
        #expect(try self.song(song.id).title == "Two (live)")
        #expect(try self.disc().title == "Side B")
        #expect(try self.disc().songs.count == 2)
    }

    @Test func aChildEditedThroughItsParentStillSaves() throws {
        var disc = try saved()
        disc.songs[0].title = "Uno"
        disc.songs.swapAt(0, 1)
        for index in disc.songs.indices {
            disc.songs[index].position = index + 1
        }
        context.insert(disc)
        try context.save()
        #expect(try self.disc().songs.map(\.title) == ["Two", "Uno"])
    }

    @Test func aLinkedCopyFromBeforeItsParentSavedKeepsItsParent() throws {
        let song = Song(title: "One", position: 1)
        var disc = Disc(title: "Side A")
        disc.songs = [song]
        context.insert(disc)
        try context.save()

        // `song` was copied before the disc saved, so it doesn't know its disc.
        context.insert(Mix(title: "Favorites", songs: [song]))
        try context.save()
        #expect(try self.song(song.id).disc == disc.id)
        #expect(try self.disc().songs.count == 1)
        #expect(try context.fetch(Mix.self).first?.songs.map(\.id) == [song.id])
    }

    @Test func aParentAndALinkInOneSaveBothHoldTheChild() throws {
        var disc = Disc(title: "Side A")
        disc.songs = [Song(title: "One", position: 1)]
        context.insert(disc)
        context.insert(Mix(title: "Favorites", songs: disc.songs))
        try context.save()
        #expect(try self.disc().songs.count == 1)
        #expect(try context.fetch(Mix.self).first?.songs.count == 1)
        #expect(try context.fetch(Song.self).count == 1)
    }

    @Test func aLinkedCopyStillSavesItsOwnEdits() throws {
        var mix = Mix(title: "Favorites", songs: try saved().songs)
        context.insert(mix)
        try context.save()
        mix = try #require(try context.fetch(Mix.self).first)
        mix.songs[0].title = "One (remix)"
        context.insert(mix)
        try context.save()
        #expect(try self.song(mix.songs[0].id).title == "One (remix)")
        #expect(try self.song(mix.songs[0].id).disc == (try disc().id))
    }
}
