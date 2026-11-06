#if canImport(SwiftUI)
import CrateModels
import SwiftUI

/// Every album, sorted as the settings say, with search, delete and add.
struct AlbumList: View {
    @Environment(\.recordContext) private var context
    @Records private var albums: [Album]
    @Records(sort: \Artist.name) private var artists: [Artist]
    @State private var search = ""
    @State private var adding = false
    @State private var failure: String?

    init(order: AlbumOrder) {
        _albums = Records(sort: order.sort)
    }

    private var artistNames: [Artist.ID: String] {
        Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0.name) })
    }

    private var shown: [Album] {
        guard !search.isEmpty else { return albums }
        let names = artistNames
        return albums.filter {
            $0.title.localizedStandardContains(search)
                || ($0.artist.flatMap { names[$0] } ?? "").localizedStandardContains(search)
                || $0.tracks.contains { $0.title.localizedStandardContains(search) }
        }
    }

    var body: some View {
        let names = artistNames
        let unsynced = $albums.unsynced
        List {
            ForEach(shown) { album in
                NavigationLink {
                    AlbumDetail(album: album)
                } label: {
                    AlbumRow(
                        album: album, artist: album.artist.flatMap { names[$0] }, synced: !unsynced.contains(album.id),
                        conflicted: context.conflict(Album.self, for: album.id) != nil
                    )
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(album) }
                }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(album) }
                }
            }
        }
        .overlay {
            if albums.isEmpty {
                ContentUnavailableView {
                    Label("An empty crate", systemImage: "opticaldisc")
                } description: {
                    Text("Add an album, or start with a sample crate of made-up records. On a second device, wait for the first one's crate to sync instead.")
                } actions: {
                    Button("Add the sample crate") { addSamples() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .searchable(text: $search, prompt: "Albums, artists, tracks")
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add album", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { NewAlbum() }
        }
        .refreshable { try? await context.refresh() }
        .alert("Couldn't save", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func delete(_ album: Album) {
        context.delete(album)
        do {
            try context.save()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func addSamples() {
        do {
            try SampleCrate.insert(into: context) { album, artist in
                CoverArt.png(title: album.title, artist: artist, year: album.year)
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct AlbumRow: View {
    var album: Album
    var artist: String?
    var synced: Bool
    var conflicted: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(data: album.cover, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.headline)
                Text([artist, String(album.year)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if album.rating > 0 {
                        Text(String(repeating: "★", count: album.rating)).foregroundStyle(.yellow)
                    }
                    Text("\(album.tracks.count) tracks · \(Track.time(album.duration))")
                    if album.plays > 0 { Text("· \(album.plays) plays") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if album.isOnLoan { Image(systemName: "person.crop.circle.badge.clock").foregroundStyle(.purple) }
            if conflicted { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            SyncBadge(synced: synced)
        }
    }
}
#endif
