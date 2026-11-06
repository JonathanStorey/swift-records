import CrateModels
import Foundation
import Testing

/// The crate's models on a device alone: relationships, property wrappers, and the merges an open edit
/// meets when a change from elsewhere arrives.
@MainActor
@Suite struct CrateModelsTests {
    let context = try! RecordContainer(for: crateTypes, location: .inMemory).mainContext

    private func seeded() throws {
        try SampleCrate.insert(into: context)
    }

    private func album(_ title: String) throws -> Album {
        try #require(try context.fetch(Album.self).first { $0.title == title })
    }

    private func artist(_ name: String) throws -> Artist {
        try #require(try context.fetch(Artist.self).first { $0.name == name })
    }

    /// Lets the context hear of a background commit.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: Relationships

    @Test func theSampleCrateLinksEverything() async throws {
        try seeded()
        #expect(try context.fetch(Artist.self).count == 5)
        #expect(try context.fetch(Album.self).count == 8)
        #expect(try context.fetch(Genre.self).count == 8)
        #expect(try context.fetch(Track.self).count == 45)

        let orchard = try artist("The Velvet Orchard")
        #expect(orchard.albums.map(\.title) == ["Copper Skies", "Paper Moons"])
        let skies = try album("Copper Skies")
        #expect(skies.artist == orchard.id)
        #expect(skies.tracks.map(\.position) == Array(1...6))
        #expect(skies.tracks.first?.title == "Morning in the Orchard")
        #expect(skies.genres.map(\.name) == ["Psychedelic", "Rock"])
        #expect(skies.duration == 1652)
    }

    @Test func genresReadTheirAlbumsFromTheOtherSide() async throws {
        try seeded()
        let rock = try #require(try context.fetch(Genre.self).first { $0.name == "Rock" })
        let titles = try rock.albumIDs.compactMap { try context.record(Album.self, for: $0)?.title }
        #expect(Set(titles) == ["Copper Skies", "Paper Moons"])
    }

    @Test func tracksStayInOrderAsTheyMove() async throws {
        try seeded()
        var album = try album("Paper Moons")
        album.tracks.reverse()
        album.renumberTracks()
        context.insert(album)
        try await context.save()
        #expect(try self.album("Paper Moons").tracks.first?.title == "Weather Vane")

        try context.addTrack("Bonus: Paper Moons (demo)", duration: 201, to: album)
        try await context.save()
        let tracks = try self.album("Paper Moons").tracks
        #expect(tracks.count == 6)
        #expect(tracks.last?.title == "Bonus: Paper Moons (demo)")
        #expect(tracks.last?.position == 6)
    }

    @Test func deletingAnAlbumDeletesItsTracksAndLoansButNotItsGenres() async throws {
        try seeded()
        let album = try album("Corazón de Neón")
        #expect(album.isOnLoan)
        context.delete(album)
        try await context.save()
        #expect(try context.fetch(Track.self).count == 40)
        #expect(try context.fetch(Loan.self).isEmpty)
        #expect(try context.fetch(Genre.self).count == 8)
        #expect(try context.fetch(Friend.self).count == 3)
    }

    @Test func deletingAnArtistLeavesTheirAlbumsWithoutOne() async throws {
        try seeded()
        context.delete(try artist("Nina Calloway"))
        try await context.save()
        #expect(try album("Blue Hour at the Lark").artist == nil)
        #expect(try album("Slow Burning").tracks.count == 6)
    }

    @Test func playlistsHoldTracksFromManyAlbums() async throws {
        try seeded()
        var playlist = try #require(try context.fetch(Playlist.self).first)
        #expect(playlist.tracks.count == 8)
        let track = playlist.tracks[0]
        #expect(try context.record(Track.self, for: track.id)?.playlistIDs == [playlist.id])

        playlist.tracks.removeFirst()
        context.insert(playlist)
        try await context.save()
        #expect(try context.record(Track.self, for: track.id)?.playlistIDs == [])
        #expect(try context.record(Track.self, for: track.id) != nil)
    }

    @Test func loansLinkAnAlbumAndAFriend() async throws {
        try seeded()
        let friend = try #require(try context.fetch(Friend.self).first { $0.name == "Priya Natarajan" })
        let loan = context.lend(try album("Salt and Timber"), to: friend, days: 7, note: "Careful with it")
        try await context.save()
        #expect(try album("Salt and Timber").isOnLoan)
        #expect(try context.record(Friend.self, for: friend.id)?.outstanding.map(\.id) == [loan.id])

        context.markReturned(loan)
        try await context.save()
        #expect(try !album("Salt and Timber").isOnLoan)
        #expect(try context.record(Friend.self, for: friend.id)?.outstanding.isEmpty == true)

        context.delete(friend)
        try await context.save()
        #expect(try album("Salt and Timber").loans.isEmpty)
    }

    // MARK: Property wrappers

    @Test func playsCountOnTheTrackAndTheAlbum() async throws {
        try seeded()
        let track = try album("Analog Bloom").tracks[2]
        try context.play(track)
        try context.play(track)
        try await context.save()
        #expect(try context.record(Track.self, for: track.id)?.plays == 2)
        #expect(try album("Analog Bloom").plays == 2)
    }

    @Test func timestampsAndCoverArtAreKept() async throws {
        let cover = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        var album = Album(title: "Test Pressing", cover: cover)
        context.insert(album)
        try await context.save()
        let stored = try #require(try context.record(Album.self, for: album.id))
        #expect(stored.cover == cover)
        #expect(stored.added != nil)
        #expect(stored.modified != nil)
        #expect(stored.synced == nil)

        album = stored
        album.cover = nil
        context.insert(album)
        try await context.save()
        #expect(try context.record(Album.self, for: album.id)?.cover == nil)
    }

    @Test func indexedFieldsFilter() async throws {
        try seeded()
        let sixties = try context.fetch(RecordDescriptor<Album>(predicate: #Predicate { $0.year < 1970 }, sortBy: [SortDescriptor(\.year)]))
        #expect(sixties.map(\.title) == ["Blue Hour at the Lark", "Slow Burning"])
        let canadian = try context.fetch(RecordDescriptor<Artist>(predicate: #Predicate { $0.country == "Canada" }))
        #expect(canadian.map(\.name) == ["Kestrel & Vine"])
    }

    @Test func albumsSortEveryWay() async throws {
        try seeded()
        var skies = try album("Copper Skies")
        skies.rating = 5
        skies.plays = 9
        context.insert(skies)
        try await context.save()
        let sorted = try AlbumOrder.allCases.map { try context.fetch(RecordDescriptor<Album>(sortBy: $0.sort)).map(\.title) }
        #expect(sorted[0].first == "Analog Bloom")
        #expect(sorted[1].first == "Blue Hour at the Lark")
        #expect(sorted[2].count == 8)
        #expect(sorted[3].first == "Copper Skies")
        #expect(sorted[4].first == "Copper Skies")
    }

    // MARK: Merging

    /// An album saved, then edited on screen without saving.
    private func openEdit(_ change: (inout Album) -> Void) throws -> Album {
        try seeded()
        var album = try album("Voltage Rain")
        change(&album)
        context.insert(album)
        return album
    }

    @Test func playsFromBothSidesAdd() async throws {
        let album = try openEdit { $0.plays += 2 }
        try await context.editElsewhere(Album.self, album.id) { $0.plays += 3 }
        await settle()
        #expect(try context.record(Album.self, for: album.id)?.plays == 5)
        try await context.save()
        #expect(try self.album("Voltage Rain").plays == 5)
    }

    @Test func theHigherRatingWins() async throws {
        let album = try openEdit { $0.rating = 3 }
        try await context.editElsewhere(Album.self, album.id) { $0.rating = 5 }
        await settle()
        try await context.save()
        #expect(try self.album("Voltage Rain").rating == 5)
        #expect(!context.conflict(Album.self, for: album.id, at: \.rating))
    }

    @Test func tagsAndCreditsMergeByPart() async throws {
        let album = try openEdit {
            $0.tags.insert("favorite")
            $0.tags.remove("double LP")
            $0.credits.label = "Kreis Records"
        }
        try await context.editElsewhere(Album.self, album.id) {
            $0.tags.insert("loaned once")
            $0.credits.catalogNumber = "KR 031-2"
        }
        await settle()
        try await context.save()
        let merged = try self.album("Voltage Rain")
        #expect(merged.tags == ["favorite", "loaned once"])
        #expect(merged.credits == Credits(producer: "Jonas Reiter", label: "Kreis Records", catalogNumber: "KR 031-2"))
    }

    @Test func aTitleBothChangedIsAConflictTheEditorSettles() async throws {
        let album = try openEdit {
            $0.title = "Voltage Rain (Deluxe)"
            $0.condition = .nearMint
        }
        try await context.editElsewhere(Album.self, album.id) {
            $0.title = "Voltage Rain (Remastered)"
            $0.year = 2020
        }
        await settle()
        let other = try #require(context.conflict(Album.self, for: album.id))
        #expect(other.title == "Voltage Rain (Remastered)")
        #expect(context.conflict(Album.self, for: album.id, at: \.title))
        #expect(!context.conflict(Album.self, for: album.id, at: \.year))
        let shown = try #require(try context.record(Album.self, for: album.id))
        #expect(shown.title == "Voltage Rain (Deluxe)")
        #expect(shown.year == 2020)

        context.resolveConflict(Album.self, for: album.id, favoring: .theirs)
        try await context.save()
        let saved = try self.album("Voltage Rain (Remastered)")
        #expect(saved.condition == .nearMint)
        #expect(context.conflict(Album.self, for: album.id) == nil)
    }

    @Test func aPlaylistMergesItself() async throws {
        try seeded()
        var playlist = try #require(try context.fetch(Playlist.self).first)
        playlist.notes = "Coffee first.\nThen records."
        playlist.pinned = false
        context.insert(playlist)
        try await context.editElsewhere(Playlist.self, playlist.id) {
            $0.notes = "Coffee first. Loud."
            $0.title = "Sunday Mornings"
            $0.pinned = true
        }
        await settle()
        try await context.save()
        let merged = try #require(try context.record(Playlist.self, for: playlist.id))
        #expect(merged.title == "Sunday Mornings")
        #expect(merged.pinned)
        #expect(merged.notes == "Coffee first.\nThen records.\nCoffee first. Loud.")
        #expect(merged.tracks.count == 8)
    }

    @Test func aTitleBothChangedMakesThePlaylistGiveUp() {
        let base = Playlist(title: "Mix", notes: "a")
        var ours = base
        ours.title = "Mix A"
        var theirs = base
        theirs.title = "Mix B"
        #expect(ours.merging(with: theirs, from: base) == nil)
        theirs.title = "Mix"
        #expect(ours.merging(with: theirs, from: base)?.title == "Mix A")
    }

    @Test func trackTimesRead() {
        #expect(Track.time(187) == "3:07")
        #expect(Track.time(3725) == "1:02:05")
    }
}
