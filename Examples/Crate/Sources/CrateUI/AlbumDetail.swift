#if canImport(SwiftUI)
import CrateModels
import PhotosUI
import SwiftUI

/// One album, edited live: every change goes to the context as it's made and shows in every list, and a
/// change from another device merges in while it's open.
struct AlbumDetail: View {
    @Recordable var album: Album
    @Environment(\.recordContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Records(sort: \Artist.name) private var artists: [Artist]
    @Records(sort: \Friend.name) private var friends: [Friend]
    @State private var editing = false
    @State private var choosingGenres = false
    @State private var lending = false
    @State private var photo: PhotosPickerItem?
    @State private var newTag = ""
    @State private var newTrack = ""

    private var artistName: String {
        album.artist.flatMap { id in artists.first { $0.id == id }?.name } ?? "Unknown artist"
    }

    var body: some View {
        Form {
            header
            if let other = $album.conflict {
                Section {
                    ConflictBanner(
                        summary: "Elsewhere: “\(other.title)”, \(other.year), rated \(other.rating), \(other.condition.label).",
                        useTheirs: { $album.resolveConflict(favoring: .theirs) },
                        keepMine: { $album.resolveConflict(favoring: .ours) }
                    )
                }
            }
            listening
            tracks
            genres
            details
            loans
            record
        }
        .formStyle(.grouped)
        .navigationTitle(album.title.isEmpty ? "Album" : album.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if $album.hasChanges {
                    Button("Revert", systemImage: "arrow.uturn.backward") { $album.rollback() }
                    Button("Save", systemImage: "checkmark.circle") { try? $album.save() }
                }
                Button("Edit", systemImage: "square.and.pencil") { editing = true }
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Draw a new cover", systemImage: "paintpalette") { drawCover() }
                    Button("Remove the cover", systemImage: "xmark.square") { album.cover = nil }
                    Button("Delete album", systemImage: "trash", role: .destructive) { $album.delete(); try? context.save() }
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { AlbumEditor(album: album) }
        }
        .sheet(isPresented: $choosingGenres) {
            NavigationStack { GenrePicker(selection: $album.genres) }
        }
        .sheet(isPresented: $lending) {
            NavigationStack { LendSheet(album: album) }
        }
        .onChange(of: $album.isDeleted) { _, deleted in
            if deleted { dismiss() }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    album.cover = data
                }
                photo = nil
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                PhotosPicker(selection: $photo, matching: .images) {
                    CoverImage(data: album.cover, size: 140)
                }
                .buttonStyle(.plain)
                .help("Choose a cover from Photos")
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Title", text: $album.title)
                        .font(.title2.bold())
                        .conflictMark($album.conflict(at: \.title))
                    Picker("Artist", selection: $album.artist) {
                        Text("Unknown artist").tag(Artist.ID?.none)
                        ForEach(artists) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .conflictMark($album.conflict(at: \.artist))
                    Stepper("Released \(String(album.year))", value: $album.year, in: 1900...2100)
                        .conflictMark($album.conflict(at: \.year))
                    if let artist = album.artist.flatMap({ id in artists.first { $0.id == id } }) {
                        NavigationLink("About \(artist.name)") { ArtistDetail(artist: artist) }
                            .font(.callout)
                    }
                }
            }
        }
    }

    private var listening: some View {
        Section("Listening") {
            LabeledContent("Rating") {
                RatingStars(rating: $album.rating, highlighted: $album.conflict(at: \.rating))
            }
            LabeledContent("Plays", value: "\(album.plays)")
            Button("Played it", systemImage: "play.circle") { album.plays += 1 }
            Text("Plays add up across devices, and the higher rating wins when both change it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var tracks: some View {
        Section {
            ForEach(album.tracks) { track in
                NavigationLink {
                    TrackDetail(track: track)
                } label: {
                    TrackRow(track: track)
                }
            }
            .onMove { from, to in
                var copy = album
                copy.tracks.move(fromOffsets: from, toOffset: to)
                copy.renumberTracks()
                album = copy
            }
            .onDelete { offsets in
                var copy = album
                copy.tracks.remove(atOffsets: offsets)
                copy.renumberTracks()
                album = copy
            }
            HStack {
                TextField("New track", text: $newTrack)
                    .onSubmit(addTrack)
                Button("Add", systemImage: "plus.circle.fill", action: addTrack)
                    .labelStyle(.iconOnly)
                    .disabled(newTrack.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Tracks")
        } footer: {
            Text("\(album.tracks.count) tracks, \(Track.time(album.duration)). Drag to reorder.")
        }
    }

    private var genres: some View {
        Section("Genres") {
            if album.genres.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(album.genres) { genre in
                NavigationLink(genre.name) { GenreDetail(genre: genre) }
            }
            Button("Choose genres", systemImage: "tag") { choosingGenres = true }
        }
    }

    private var details: some View {
        Section("Details") {
            Picker("Condition", selection: $album.condition) {
                ForEach(Condition.allCases) { Text($0.label).tag($0) }
            }
            .conflictMark($album.conflict(at: \.condition))
            TextField("Producer", text: $album.credits.producer)
            TextField("Label", text: $album.credits.label)
            TextField("Catalog number", text: $album.credits.catalogNumber)
            TextField("Price paid", value: $album.price, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            tagEditor
            VStack(alignment: .leading) {
                Text("Liner notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $album.linerNotes)
                    .frame(minHeight: 80)
                    .conflictMark($album.conflict(at: \.linerNotes))
            }
        }
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(album.tags.sorted(), id: \.self) { tag in
                        Button {
                            album.tags.remove(tag)
                        } label: {
                            Label(tag, systemImage: "xmark").labelStyle(TrailingIconLabel())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            TextField("Add a tag", text: $newTag)
                .onSubmit {
                    let tag = newTag.trimmingCharacters(in: .whitespaces).lowercased()
                    if !tag.isEmpty { album.tags.insert(tag) }
                    newTag = ""
                }
        }
    }

    private var loans: some View {
        Section("Loans") {
            ForEach(album.loans.sorted { $0.lentOn > $1.lentOn }) { loan in
                LoanRow(loan: loan, title: friends.first { $0.id == loan.friend }?.name ?? "Someone")
            }
            if !album.isOnLoan {
                Button("Lend to a friend", systemImage: "person.badge.plus") { lending = true }
                    .disabled($album.isNew)
            }
        }
    }

    private var record: some View {
        Section("Record") {
            LabeledContent("Added", value: album.added?.shortly ?? "Not saved")
            LabeledContent("Last edited", value: album.modified?.shortly ?? "Not saved")
            LabeledContent("Last synced", value: album.synced?.shortly ?? "Never")
            LabeledContent("On the server") { SyncBadge(synced: $album.isSynced) }
            LabeledContent("Unsaved edits", value: $album.hasChanges ? "Yes" : "No")
            LabeledContent("ID", value: album.id.uuidString).font(.caption.monospaced())
        }
    }

    // MARK: Actions

    private func addTrack() {
        let title = newTrack.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        var copy = album
        copy.tracks.append(Track(title: title, position: copy.nextPosition, duration: 180))
        album = copy
        newTrack = ""
    }

    private func drawCover() {
        album.cover = CoverArt.png(title: album.title, artist: artistName, year: album.year)
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

struct TrackRow: View {
    var track: Track
    @RecordStorage private var settings = CrateSettings()

    var body: some View {
        HStack {
            if settings.showTrackNumbers {
                Text("\(track.position)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing)
            }
            Text(track.title)
            if track.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            Spacer()
            if track.plays > 0 { Text("\(track.plays)▶︎").font(.caption).foregroundStyle(.secondary) }
            Text(track.time).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// One track, edited live.
struct TrackDetail: View {
    @Recordable var track: Track
    @Records private var playlists: [Playlist]
    @Environment(\.recordContext) private var context
    @Environment(\.dismiss) private var dismiss

    init(track: Track) {
        _track = Recordable(wrappedValue: track)
        _playlists = Records(ids: track.playlistIDs)
    }

    var body: some View {
        Form {
            if let other = $track.conflict {
                ConflictBanner(
                    summary: "Elsewhere: “\(other.title)”, \(Track.time(other.duration)).",
                    useTheirs: { $track.resolveConflict(favoring: .theirs) },
                    keepMine: { $track.resolveConflict(favoring: .ours) }
                )
            }
            TextField("Title", text: $track.title).conflictMark($track.conflict(at: \.title))
            Stepper("Length \(track.time)", value: $track.duration, in: 0...3600, step: 5)
            Toggle("Favorite", isOn: $track.favorite)
            LabeledContent("Plays", value: "\(track.plays)")
            Button("Play", systemImage: "play.fill") { try? context.play(track) }
            Section("In playlists") {
                if playlists.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(playlists) { Text($0.title) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(track.title)
        .onChange(of: $track.isDeleted) { _, deleted in
            if deleted { dismiss() }
        }
    }
}
#endif
