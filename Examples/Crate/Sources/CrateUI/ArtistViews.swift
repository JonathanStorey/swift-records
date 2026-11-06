#if canImport(SwiftUI)
import CrateModels
import SwiftUI

/// Artists a page at a time, to exercise a descriptor's `fetchLimit` and the paging on `$artists`.
struct ArtistList: View {
    @Environment(\.recordContext) private var context
    @Records(RecordDescriptor<Artist>(sortBy: [SortDescriptor(\.name)], fetchLimit: 4)) private var artists: [Artist]
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(artists) { artist in
                    NavigationLink {
                        ArtistDetail(artist: artist)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(artist.name).font(.headline)
                            Text("\(artist.country) · \(artist.albums.count) albums").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    $artists.delete(atOffsets: offsets)
                    try? $artists.save()
                }
            } footer: {
                Text("Page \($artists.page + 1) of \(max($artists.pageCount, 1)), \($artists.totalCount) artists. Deleting an artist keeps their albums.")
            }
            Section {
                HStack {
                    Button("Previous", systemImage: "chevron.left") { $artists.previousPage() }
                        .disabled(!$artists.hasPreviousPage)
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { $artists.nextPage() }
                        .disabled(!$artists.hasNextPage)
                }
                .buttonStyle(.borderless)
            }
        }
        .navigationTitle("Artists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add artist", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { NewArtist() }
        }
    }
}

/// A new artist, edited live: the first keystroke inserts it, so it shows in the list behind the sheet.
struct NewArtist: View {
    @Recordable var artist = Artist()
    @Environment(\.recordContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $artist.name)
            TextField("Country", text: $artist.country)
            TextField("Biography", text: $artist.bio, axis: .vertical)
            Text($artist.isNew ? "Not inserted yet." : "Inserted. It shows in the list now.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("New artist")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    $artist.rollback()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? context.save()
                    dismiss()
                }
                .disabled(artist.name.isEmpty)
            }
        }
    }
}

struct ArtistDetail: View {
    @Recordable var artist: Artist
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $artist.name).font(.title3.bold())
                TextField("Country", text: $artist.country)
                TextField("Biography", text: $artist.bio, axis: .vertical).lineLimit(3...8)
            }
            Section("Albums") {
                if artist.albums.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(artist.albums) { album in
                    NavigationLink {
                        AlbumDetail(album: album)
                    } label: {
                        HStack {
                            CoverImage(data: album.cover, size: 40)
                            Text(album.title)
                            Spacer()
                            Text(String(album.year)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Added", value: artist.added?.shortly ?? "Not saved")
                LabeledContent("On the server") { SyncBadge(synced: $artist.isSynced) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(artist.name)
        .onChange(of: $artist.isDeleted) { _, deleted in
            if deleted { dismiss() }
        }
    }
}

/// Every genre and how many albums use it.
struct GenreList: View {
    @Records(sort: \Genre.name) private var genres: [Genre]

    var body: some View {
        List {
            ForEach(genres) { genre in
                NavigationLink {
                    GenreDetail(genre: genre)
                } label: {
                    LabeledContent(genre.name, value: "\(genre.albumIDs.count)")
                }
            }
            .onDelete { offsets in
                $genres.delete(atOffsets: offsets)
                try? $genres.save()
            }
        }
        .navigationTitle("Genres")
    }
}

/// A genre's albums, read from the other side of `Album.genres` with `@Records(ids:)`.
struct GenreDetail: View {
    @Recordable var genre: Genre
    @Records private var albums: [Album]

    init(genre: Genre) {
        _genre = Recordable(wrappedValue: genre)
        _albums = Records(ids: genre.albumIDs)
    }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $genre.name)
            }
            Section("\(albums.count) albums") {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetail(album: album)
                    } label: {
                        HStack {
                            CoverImage(data: album.cover, size: 40)
                            Text(album.title)
                        }
                    }
                }
            }
        }
        .navigationTitle(genre.name)
    }
}
#endif
