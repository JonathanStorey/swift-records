#if canImport(SwiftUI)
import CrateModels
import SwiftUI

/// A sheet with Save and Cancel. Its edits stay in a draft that no list sees until Save, and a change from
/// another device still merges into the fields the draft left alone.
struct AlbumEditor: View {
    @Recordable var album: Album
    @Environment(\.dismiss) private var dismiss
    @Records(sort: \Artist.name) private var artists: [Artist]
    @State private var failure: String?

    init(album: Album) {
        _album = Recordable(wrappedValue: album, .draft)
    }

    var body: some View {
        Form {
            if let other = $album.conflict {
                ConflictBanner(
                    summary: "Elsewhere: “\(other.title)”, \(other.year), \(other.condition.label).",
                    useTheirs: { $album.resolveConflict(favoring: .theirs) },
                    keepMine: { $album.resolveConflict(favoring: .ours) }
                )
            }
            AlbumFields(album: $album.binding, artists: artists, conflict: { $album.conflict(at: $0) })
            if $album.isDeleted {
                Text("Deleted on another device. Save brings it back, and Cancel lets it go.")
                    .foregroundStyle(.red)
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Edit album")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    $album.rollback()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!$album.hasChanges && !$album.isDeleted)
            }
        }
    }

    private func save() {
        do {
            try $album.save()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A new album in a draft: nothing is inserted until Add, and Add Another starts a fresh one.
struct NewAlbum: View {
    @Recordable(.draft) var album = Album(title: "", year: Calendar.current.component(.year, from: Date()))
    @Environment(\.dismiss) private var dismiss
    @Records(sort: \Artist.name) private var artists: [Artist]
    @State private var added = 0
    @State private var failure: String?

    var body: some View {
        Form {
            AlbumFields(album: $album.binding, artists: artists, conflict: { _ in false })
            if added > 0 {
                Text("Added \(added) so far.").foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New album")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(added > 0 ? "Done" : "Cancel") {
                    $album.rollback()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    if add() { dismiss() }
                }
                .disabled(album.title.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Add Another") {
                    if add() { $album.startNew() }
                }
                .disabled(album.title.isEmpty)
            }
        }
    }

    private func add() -> Bool {
        if album.cover == nil {
            let artist = album.artist.flatMap { id in artists.first { $0.id == id }?.name } ?? ""
            album.cover = CoverArt.png(title: album.title, artist: artist, year: album.year)
        }
        do {
            try $album.save()
            added += 1
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
}

/// The fields the editor and the new album sheet share.
struct AlbumFields: View {
    @Binding var album: Album
    var artists: [Artist]
    var conflict: (PartialKeyPath<Album>) -> Bool

    var body: some View {
        Section("Album") {
            TextField("Title", text: $album.title).conflictMark(conflict(\.title))
            Picker("Artist", selection: $album.artist) {
                Text("Unknown artist").tag(Artist.ID?.none)
                ForEach(artists) { Text($0.name).tag(Optional($0.id)) }
            }
            .conflictMark(conflict(\.artist))
            Stepper("Released \(String(album.year))", value: $album.year, in: 1900...2100)
                .conflictMark(conflict(\.year))
            Picker("Condition", selection: $album.condition) {
                ForEach(Condition.allCases) { Text($0.label).tag($0) }
            }
            .conflictMark(conflict(\.condition))
            LabeledContent("Rating") { RatingStars(rating: $album.rating, highlighted: conflict(\.rating)) }
        }
        Section("Credits") {
            TextField("Producer", text: $album.credits.producer)
            TextField("Label", text: $album.credits.label)
            TextField("Catalog number", text: $album.credits.catalogNumber)
            TextField("Price paid", value: $album.price, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
        }
        Section("Liner notes") {
            TextEditor(text: $album.linerNotes).frame(minHeight: 100).conflictMark(conflict(\.linerNotes))
        }
    }
}

/// Picks an album's genres from every genre, and adds new ones.
struct GenrePicker: View {
    @Binding var selection: [Genre]
    @Records(sort: \Genre.name) private var genres: [Genre]
    @Environment(\.recordContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var newGenre = ""

    var body: some View {
        List {
            ForEach(genres) { genre in
                let chosen = selection.contains { $0.id == genre.id }
                Button {
                    if chosen {
                        selection.removeAll { $0.id == genre.id }
                    } else {
                        selection.append(genre)
                    }
                } label: {
                    HStack {
                        Text(genre.name).foregroundStyle(Color.primary)
                        Spacer()
                        if chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
            HStack {
                TextField("New genre", text: $newGenre).onSubmit(add)
                Button("Add", action: add).disabled(newGenre.isEmpty)
            }
        }
        .navigationTitle("Genres")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func add() {
        let name = newGenre.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let genre = Genre(name: name)
        context.insert(genre)
        selection.append(genre)
        newGenre = ""
    }
}
#endif
