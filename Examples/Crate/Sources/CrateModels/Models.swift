import Foundation
@_exported import Identification
@_exported import SwiftRecords

// Every relationship SwiftRecords offers, and every property wrapper, in one record collection:
//
// - Artist → Album: one to many, through the album's `artist` pointer, which `.nullify` clears.
// - Album → Track: one to many in order, sorted by `position`, and deleting the album deletes them.
// - Album ↔ Genre: many to many as a plain link, with Genre reading the other side as a set of IDs.
// - Playlist ↔ Track: many to many in the playlist's own order, on a record that merges itself.
// - Album ↔ Friend through Loan: a link with properties of its own, deleted with either end.

/// A band or a solo artist.
@Record
public struct Artist {
    public var id = UUID.timestamp
    public var name = ""
    @Indexed public var country = ""
    public var bio = ""
    /// The albums whose `artist` names this artist, by year.
    @Reference(to: \Album.artist, sort: \.year) public var albums: [Album] = []
    @Timestamped(.created) public var added: Date?

    public init(name: String = "", country: String = "", bio: String = "") {
        self.name = name
        self.country = country
        self.bio = bio
    }
}

/// How worn a record is, from the sleeve to the grooves.
public enum Condition: String, Codable, Sendable, CaseIterable, Identifiable {
    case mint, nearMint, veryGood, good, fair, poor

    public var id: Self { self }

    public var label: String {
        switch self {
        case .mint: "Mint"
        case .nearMint: "Near mint"
        case .veryGood: "Very good"
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }
}

/// What the sleeve says about who made the record. It merges property by property, so a label fixed on one
/// device and a producer on another both stay.
public struct Credits: Codable, Hashable, Sendable {
    public var producer = ""
    public var label = ""
    public var catalogNumber = ""

    public init(producer: String = "", label: String = "", catalogNumber: String = "") {
        self.producer = producer
        self.label = label
        self.catalogNumber = catalogNumber
    }
}

/// One record in the crate.
@Record
public struct Album {
    public var id = UUID.timestamp
    public var title = ""
    @Indexed public var year = 2000
    @Reference(from: Artist.self, action: .nullify) public var artist: Artist.ID?
    @Reference(to: \Track.album, sort: \.position) public var tracks: [Track] = []
    @Reference(to: Genre.self, sort: \.name) public var genres: [Genre] = []
    @Reference(to: \Loan.album) public var loans: [Loan] = []
    /// The cover, as PNG or JPEG. The phone's copy and the Mac's merge as whole files, the later edit winning.
    @Asset public var cover: Data?
    public var condition = Condition.veryGood
    public var credits = Credits()
    /// Additions and removals from both devices apply.
    public var tags: Set<String> = []
    /// Both devices' plays count.
    @Merged(.sum) public var plays = 0
    /// The highest rating either device gave wins.
    @Merged(.maximum) public var rating = 0
    /// What was paid, kept in CloudKit's encrypted fields.
    @Encrypted public var price = 0.0
    /// Called `notes` before version 2, which this still reads.
    @Renamed(from: "notes") public var linerNotes = ""
    @Timestamped(.created) public var added: Date?
    @Timestamped(.modified) public var modified: Date?
    @Timestamped(.synced) public var synced: Date?

    public init(
        title: String = "", year: Int = 2000, artist: Artist.ID? = nil, tracks: [Track] = [], genres: [Genre] = [],
        cover: Data? = nil, condition: Condition = .veryGood, credits: Credits = Credits(), tags: Set<String> = [],
        price: Double = 0, linerNotes: String = ""
    ) {
        self.title = title
        self.year = year
        self.artist = artist
        self.tracks = tracks
        self.genres = genres
        self.cover = cover
        self.condition = condition
        self.credits = credits
        self.tags = tags
        self.price = price
        self.linerNotes = linerNotes
    }

    /// The running time of every track.
    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }

    /// Whether a friend has it now.
    public var isOnLoan: Bool { loans.contains { !$0.returned } }

    /// The next position for a track added at the end.
    public var nextPosition: Int { (tracks.map(\.position).max() ?? 0) + 1 }

    /// Puts the tracks in this order, numbering them from 1.
    public mutating func renumberTracks() {
        for index in tracks.indices {
            tracks[index].position = index + 1
        }
    }
}

/// One song on an album.
@Record
public struct Track {
    public var id = UUID.timestamp
    public var title = ""
    public var position = 1
    /// Seconds.
    public var duration: TimeInterval = 0
    public var favorite = false
    @Merged(.sum) public var plays = 0
    @Reference(from: Album.self, action: .deleteSelf) public var album: Album.ID?
    /// The playlists that include it.
    @Reference(to: \Playlist.tracks) public var playlistIDs: Set<Playlist.ID>

    public init(title: String = "", position: Int = 1, duration: TimeInterval = 0, favorite: Bool = false) {
        self.title = title
        self.position = position
        self.duration = duration
        self.favorite = favorite
    }

    /// `3:07`.
    public var time: String { Self.time(duration) }

    public static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A style, shared by many albums.
@Record
public struct Genre {
    public var id = UUID.timestamp
    public var name = ""
    /// The albums linked to it, read from the other side of `Album.genres`.
    @Reference(to: \Album.genres) public var albumIDs: Set<Album.ID>

    public init(name: String = "") {
        self.name = name
    }
}

/// Tracks from anywhere in the crate, in an order of the listener's choosing. It merges itself: a title
/// both devices changed is a conflict the usual merge settles, a pin anywhere keeps it pinned, and notes
/// both devices wrote keep both.
@Record
public struct Playlist: Mergeable {
    public var id = UUID.timestamp
    public var title = ""
    public var pinned = false
    public var notes = ""
    @Reference(to: Track.self) public var tracks: [Track] = []
    @Timestamped(.modified) public var modified: Date?

    public init(title: String = "", pinned: Bool = false, notes: String = "", tracks: [Track] = []) {
        self.title = title
        self.pinned = pinned
        self.notes = notes
        self.tracks = tracks
    }

    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }

    public func merging(with theirs: Playlist, from base: Playlist) -> Playlist? {
        var merged = self
        switch (title == base.title, theirs.title == base.title) {
        case (true, false): merged.title = theirs.title
        case (false, false) where title != theirs.title: return nil
        default: break
        }
        merged.pinned = pinned || theirs.pinned
        merged.notes = Self.merge(notes, theirs.notes, base: base.notes)
        return merged
    }

    /// One side's notes when only it changed them, and both, ours first, when both did.
    static func merge(_ ours: String, _ theirs: String, base: String) -> String {
        if ours == theirs || theirs == base { return ours }
        if ours == base { return theirs }
        return ours + "\n" + theirs
    }
}

/// Someone who borrows records.
@Record
public struct Friend {
    public var id = UUID.timestamp
    public var name = ""
    public var phone = ""
    @Reference(to: \Loan.friend, sort: \.lentOn) public var loans: [Loan] = []

    public init(name: String = "", phone: String = "") {
        self.name = name
        self.phone = phone
    }

    /// The records they have now.
    public var outstanding: [Loan] { loans.filter { !$0.returned } }
}

/// An album lent to a friend: a link between the two with properties of its own.
@Record
public struct Loan {
    public var id = UUID.timestamp
    @Reference(from: Album.self, action: .deleteSelf) public var album: Album.ID?
    @Reference(from: Friend.self, action: .deleteSelf) public var friend: Friend.ID?
    public var lentOn = Date()
    public var due: Date?
    public var returned = false
    public var note = ""

    public init(album: Album.ID?, friend: Friend.ID?, lentOn: Date = Date(), due: Date? = nil, note: String = "") {
        self.album = album
        self.friend = friend
        self.lentOn = lentOn
        self.due = due
        self.note = note
    }

    public var isOverdue: Bool { !returned && (due.map { $0 < Date() } ?? false) }
}

/// How the album list sorts.
public enum AlbumOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case title, year, added, rating, plays

    public var id: Self { self }

    public var label: String { rawValue.capitalized }

    /// The album list's sort, newest or highest first where that reads naturally.
    public var sort: [SortDescriptor<Album>] {
        switch self {
        case .title: [SortDescriptor(\.title)]
        case .year: [SortDescriptor(\.year), SortDescriptor(\.title)]
        case .added: [SortDescriptor(\.added, order: .reverse)]
        case .rating: [SortDescriptor(\.rating, order: .reverse), SortDescriptor(\.title)]
        case .plays: [SortDescriptor(\.plays, order: .reverse), SortDescriptor(\.title)]
        }
    }
}

/// The app's settings, kept by `@RecordStorage` in a zone of their own and synced like any record.
@Record
public struct CrateSettings {
    public var id = UUID.timestamp
    public var listener = ""
    public var albumOrder = AlbumOrder.title
    public var showTrackNumbers = true
    public var loanDays = 14
    /// Seconds an edit pauses before it saves and syncs, or 0 to save only when the app leaves.
    public var autosaveDelay = 0

    public init() {}
}

/// Every record type, for opening the container.
public let crateTypes: [any Record.Type] = [
    Artist.self, Album.self, Track.self, Genre.self, Playlist.self, Friend.self, Loan.self, CrateSettings.self,
]
