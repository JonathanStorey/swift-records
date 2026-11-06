import Foundation

/// A starter crate of made-up artists and albums, for a first launch and for previews.
public enum SampleCrate {
    struct AlbumSeed {
        var title: String
        var year: Int
        var genres: [String]
        var condition: Condition
        var credits: Credits
        var tags: Set<String>
        var price: Double
        var tracks: [(String, TimeInterval)]
    }

    struct ArtistSeed {
        var name: String
        var country: String
        var bio: String
        var albums: [AlbumSeed]
    }

    static let artists: [ArtistSeed] = [
        ArtistSeed(
            name: "The Velvet Orchard", country: "United Kingdom",
            bio: "A four-piece from Bristol that layered harmonies over fuzz guitars for most of the seventies.",
            albums: [
                AlbumSeed(
                    title: "Copper Skies", year: 1971, genres: ["Rock", "Psychedelic"], condition: .veryGood,
                    credits: Credits(producer: "Miles Avery", label: "Harvest Lane", catalogNumber: "HL 2041"),
                    tags: ["gatefold", "first press"], price: 42,
                    tracks: [
                        ("Morning in the Orchard", 247), ("Copper Skies", 312), ("Lantern Road", 198),
                        ("Halfway to Avalon", 405), ("The Quiet Machine", 266), ("Goodnight, Severn", 224),
                    ]
                ),
                AlbumSeed(
                    title: "Paper Moons", year: 1974, genres: ["Rock"], condition: .good,
                    credits: Credits(producer: "Miles Avery", label: "Harvest Lane", catalogNumber: "HL 2188"),
                    tags: ["reissue"], price: 18,
                    tracks: [
                        ("Paper Moons", 233), ("Signal Fires", 281), ("All the Clocks", 302),
                        ("Small Hours", 189), ("Weather Vane", 344),
                    ]
                ),
            ]
        ),
        ArtistSeed(
            name: "Nina Calloway", country: "United States",
            bio: "A jazz pianist and singer who recorded her best work live in small New York clubs.",
            albums: [
                AlbumSeed(
                    title: "Blue Hour at the Lark", year: 1962, genres: ["Jazz"], condition: .nearMint,
                    credits: Credits(producer: "Sol Brenner", label: "Ridgeway", catalogNumber: "RW 7710"),
                    tags: ["live", "mono"], price: 65,
                    tracks: [
                        ("Lark Street Shuffle", 318), ("You Never Said", 274), ("Blue Hour", 421),
                        ("Rain on Sixth", 256), ("Last Call Waltz", 389),
                    ]
                ),
                AlbumSeed(
                    title: "Slow Burning", year: 1966, genres: ["Jazz", "Soul"], condition: .veryGood,
                    credits: Credits(producer: "Sol Brenner", label: "Ridgeway", catalogNumber: "RW 7802"),
                    tags: ["stereo"], price: 30,
                    tracks: [
                        ("Slow Burning", 296), ("Hold the Light", 233), ("Midnight Ferry", 347),
                        ("Tell Me Twice", 211), ("Embers", 402), ("After Hours", 268),
                    ]
                ),
            ]
        ),
        ArtistSeed(
            name: "Kestrel & Vine", country: "Canada",
            bio: "A duo from Halifax trading verses over banjo and pump organ.",
            albums: [
                AlbumSeed(
                    title: "Salt and Timber", year: 2009, genres: ["Folk"], condition: .mint,
                    credits: Credits(producer: "Ada Lindqvist", label: "Tidewater", catalogNumber: "TW-033"),
                    tags: ["180 gram", "signed"], price: 28,
                    tracks: [
                        ("Salt and Timber", 214), ("The Lighthouse Keeper", 263), ("Fog Bell", 187),
                        ("Northbound", 241), ("Widow's Walk", 299), ("Harbour Lights", 226), ("Ebb", 172),
                    ]
                ),
            ]
        ),
        ArtistSeed(
            name: "Circuit Garden", country: "Germany",
            bio: "A Berlin electronic project built on modular synthesizers and found sounds.",
            albums: [
                AlbumSeed(
                    title: "Analog Bloom", year: 2016, genres: ["Electronic", "Ambient"], condition: .nearMint,
                    credits: Credits(producer: "Jonas Reiter", label: "Kreis", catalogNumber: "KR 019"),
                    tags: ["colored vinyl"], price: 24,
                    tracks: [
                        ("Seedling", 362), ("Photosynthesis", 455), ("Analog Bloom", 512),
                        ("Night Pollen", 397), ("Root System", 604),
                    ]
                ),
                AlbumSeed(
                    title: "Voltage Rain", year: 2019, genres: ["Electronic"], condition: .mint,
                    credits: Credits(producer: "Jonas Reiter", label: "Kreis", catalogNumber: "KR 031"),
                    tags: ["double LP"], price: 32,
                    tracks: [
                        ("Static Front", 288), ("Voltage Rain", 341), ("Grounded", 276),
                        ("Thunderhead", 433), ("Clear Skies Protocol", 367), ("Drift", 512),
                    ]
                ),
            ]
        ),
        ArtistSeed(
            name: "Marisol Reyes", country: "Mexico",
            bio: "A singer-songwriter whose boleros borrow from cumbia and seventies soul.",
            albums: [
                AlbumSeed(
                    title: "Corazón de Neón", year: 2021, genres: ["Latin", "Soul"], condition: .veryGood,
                    credits: Credits(producer: "Tomás Ibarra", label: "Luz Norte", catalogNumber: "LN 104"),
                    tags: ["first press"], price: 26,
                    tracks: [
                        ("Corazón de Neón", 221), ("Ciudad Despierta", 254), ("Luna Prestada", 238),
                        ("Bolero del Tren", 276), ("Último Baile", 302),
                    ]
                ),
            ]
        ),
    ]

    static let friends: [(String, String)] = [("Sam Okafor", "555-0142"), ("Priya Natarajan", "555-0178"), ("Leo Hartmann", "555-0115")]

    /// The artists, each with their albums, tracks and genres, ready to insert, and friends to lend to.
    public static func records() -> (artists: [Artist], albums: [Album], friends: [Friend], playlist: Playlist) {
        var genres: [String: Genre] = [:]
        var artists: [Artist] = []
        var albums: [Album] = []
        for seed in Self.artists {
            let artist = Artist(name: seed.name, country: seed.country, bio: seed.bio)
            artists.append(artist)
            for albumSeed in seed.albums {
                var album = Album(
                    title: albumSeed.title, year: albumSeed.year, artist: artist.id, condition: albumSeed.condition,
                    credits: albumSeed.credits, tags: albumSeed.tags, price: albumSeed.price
                )
                album.genres = albumSeed.genres.map { name in
                    if let genre = genres[name] { return genre }
                    let genre = Genre(name: name)
                    genres[name] = genre
                    return genre
                }
                album.tracks = albumSeed.tracks.enumerated().map { index, track in
                    Track(title: track.0, position: index + 1, duration: track.1)
                }
                albums.append(album)
            }
        }
        let friends = Self.friends.map { Friend(name: $0.0, phone: $0.1) }
        let favorites = albums.sorted { $0.year < $1.year }.compactMap { $0.tracks.dropFirst().first }
        let playlist = Playlist(title: "Sunday Morning", pinned: true, notes: "Coffee first.", tracks: favorites)
        return (artists, albums, friends, playlist)
    }

    /// Fills an empty crate. Covers come from `art`, given each album and its artist's name, which the app
    /// draws, and the tests leave out.
    @MainActor
    public static func insert(into context: RecordContext, art: (Album, String) -> Data? = { _, _ in nil }) throws {
        let (artists, albums, friends, playlist) = records()
        let names = Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0.name) })
        try context.transaction {
            for artist in artists {
                context.insert(artist)
            }
            for var album in albums {
                album.cover = art(album, album.artist.flatMap { names[$0] } ?? "")
                context.insert(album)
            }
            for friend in friends {
                context.insert(friend)
            }
            context.insert(playlist)
            if let album = albums.last, let friend = friends.first {
                context.insert(Loan(album: album.id, friend: friend.id, due: Date().addingTimeInterval(14 * 86_400)))
            }
        }
    }
}
