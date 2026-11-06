#if canImport(SwiftUI)
import CrateModels
import SwiftUI

/// Playlists, pinned first.
struct PlaylistList: View {
    @Environment(\.recordContext) private var context
    @Records(sort: \Playlist.title) private var playlists: [Playlist]

    private var ordered: [Playlist] {
        playlists.filter(\.pinned) + playlists.filter { !$0.pinned }
    }

    var body: some View {
        List {
            ForEach(ordered) { playlist in
                NavigationLink {
                    PlaylistDetail(playlist: playlist)
                } label: {
                    HStack {
                        if playlist.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                        VStack(alignment: .leading) {
                            Text(playlist.title.isEmpty ? "Untitled" : playlist.title).font(.headline)
                            Text("\(playlist.tracks.count) tracks · \(Track.time(playlist.duration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        context.delete(playlist)
                        try? context.save()
                    }
                }
            }
        }
        .overlay {
            if playlists.isEmpty {
                ContentUnavailableView("No playlists", systemImage: "music.note.list", description: Text("Tap + to make one."))
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New playlist", systemImage: "plus") {
                    context.insert(Playlist(title: "New playlist"))
                    try? context.save()
                }
            }
        }
    }
}

/// A playlist, edited live. Playlist merges itself, so the Conflict Lab's edit shows its own rules.
struct PlaylistDetail: View {
    @Recordable var playlist: Playlist
    @Environment(\.recordContext) private var context
    @State private var adding = false

    var body: some View {
        Form {
            if let other = $playlist.conflict {
                ConflictBanner(
                    summary: "Elsewhere: “\(other.title)”.",
                    useTheirs: { $playlist.resolveConflict(favoring: .theirs) },
                    keepMine: { $playlist.resolveConflict(favoring: .ours) }
                )
            }
            Section {
                TextField("Title", text: $playlist.title).font(.title3.bold()).conflictMark($playlist.conflict(at: \.title))
                Toggle("Pinned", isOn: $playlist.pinned)
                TextField("Notes", text: $playlist.notes, axis: .vertical).lineLimit(2...6)
            } footer: {
                Text("Merges itself: a pin on either device wins, notes both devices wrote keep both, and a title both changed goes to the later edit.")
            }
            Section("\(playlist.tracks.count) tracks · \(Track.time(playlist.duration))") {
                ForEach(playlist.tracks) { track in
                    HStack {
                        Text(track.title)
                        Spacer()
                        Text(track.time).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .onMove { from, to in playlist.tracks.move(fromOffsets: from, toOffset: to) }
                .onDelete { playlist.tracks.remove(atOffsets: $0) }
                Button("Add tracks", systemImage: "plus") { adding = true }
            }
            Section("Try a merge") {
                Button("Simulate another device's edit", systemImage: "iphone.and.arrow.forward") {
                    let id = playlist.id
                    Task {
                        try? await context.editElsewhere(Playlist.self, id) { other in
                            other.title += " (theirs)"
                            other.notes += other.notes.isEmpty ? "Edited elsewhere." : "\nEdited elsewhere."
                            other.pinned = true
                        }
                    }
                }
                Text("Change the title or notes first without saving, then tap it. With no edit open, the change simply arrives.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Last edited", value: playlist.modified?.shortly ?? "Not saved")
                LabeledContent("On the server") { SyncBadge(synced: $playlist.isSynced) }
                if $playlist.hasChanges {
                    Button("Save now") { try? $playlist.save() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(playlist.title)
        .sheet(isPresented: $adding) {
            NavigationStack { TrackPicker(selection: $playlist.tracks) }
        }
    }
}

/// Picks tracks from every album.
struct TrackPicker: View {
    @Binding var selection: [Track]
    @Records(sort: \Album.title) private var albums: [Album]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(albums) { album in
                Section(album.title) {
                    ForEach(album.tracks) { track in
                        let chosen = selection.contains { $0.id == track.id }
                        Button {
                            if chosen {
                                selection.removeAll { $0.id == track.id }
                            } else {
                                selection.append(track)
                            }
                        } label: {
                            HStack {
                                Text(track.title).foregroundStyle(Color.primary)
                                Spacer()
                                if chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Add tracks")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}
#endif
