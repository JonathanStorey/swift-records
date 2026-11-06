import Foundation

/// The crate's everyday actions, kept here so the app and the tests run the same code.
@MainActor
extension RecordContext {
    /// Counts a play of the track and of its album.
    public func play(_ track: Track) throws {
        var track = try record(Track.self, for: track.id) ?? track
        // The album first: inserting it saves the copies of its tracks it holds, so the track's own edit goes last.
        if let albumID = track.album, var album = try record(Album.self, for: albumID) {
            album.plays += 1
            insert(album)
        }
        track.plays += 1
        insert(track)
    }

    /// Lends the album to a friend for `days` days.
    @discardableResult
    public func lend(_ album: Album, to friend: Friend, days: Int, note: String = "") -> Loan {
        let loan = Loan(
            album: album.id, friend: friend.id, due: Calendar.current.date(byAdding: .day, value: days, to: Date()), note: note
        )
        insert(loan)
        return loan
    }

    /// Marks the loan as returned.
    public func markReturned(_ loan: Loan) {
        var loan = loan
        loan.returned = true
        insert(loan)
    }

    /// Adds a track at the end of the album.
    @discardableResult
    public func addTrack(_ title: String, duration: TimeInterval, to album: Album) throws -> Track {
        var album = try record(Album.self, for: album.id) ?? album
        let track = Track(title: title, position: album.nextPosition, duration: duration)
        album.tracks.append(track)
        insert(album)
        return track
    }

    /// Saves a change to the record as another device's sync would, in a background context, so an open
    /// editor takes it in, or shows a conflict where both changed the same field.
    public func editElsewhere<R: Record>(
        _ type: R.Type, _ id: R.ID, _ change: @escaping @Sendable (inout R) -> Void
    ) async throws {
        try await performInBackground { background in
            guard var record = try background.record(R.self, for: id) else { return }
            change(&record)
            try background.insert(record)
        }
    }
}
