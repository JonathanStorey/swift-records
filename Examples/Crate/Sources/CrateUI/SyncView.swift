#if canImport(SwiftUI)
import CrateModels
import SwiftUI

/// Where sync stands, the settings, and the Conflict Lab, which edits an album from "another device" while
/// it's open here.
struct SyncView: View {
    @Environment(\.recordContext) private var context
    @RecordStorage private var settings = CrateSettings()
    @Records(sort: \Album.title) private var albums: [Album]
    @State private var refreshing = false
    @State private var lastError: String?
    @State private var labAlbum: Album.ID?
    @State private var confirmingErase = false

    var body: some View {
        Form {
            Section("Sync") {
                LabeledContent("Status") { StatusLabel(status: context.status) }
                LabeledContent("Not on the server yet", value: "\(context.unsynced.count) records")
                LabeledContent("Unsaved changes", value: "\(context.unsavedChangeCount)")
                Button {
                    Task { await refresh() }
                } label: {
                    if refreshing {
                        ProgressView()
                    } else {
                        Label("Save and sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(refreshing)
                if let lastError { Text(lastError).foregroundStyle(.red).font(.footnote) }
            }

            Section {
                TextField("Your name", text: $settings.listener)
                Picker("Sort albums by", selection: $settings.albumOrder) {
                    ForEach(AlbumOrder.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show track numbers", isOn: $settings.showTrackNumbers)
                Stepper("Lend for \(settings.loanDays) days", value: $settings.loanDays, in: 1...90)
                Picker("Autosave", selection: $settings.autosaveDelay) {
                    Text("When the app leaves").tag(0)
                    Text("After 2 seconds").tag(2)
                    Text("After 10 seconds").tag(10)
                }
                Button("Restore default settings") { $settings.restoreDefault() }
            } header: {
                Text("Settings")
            } footer: {
                Text("Settings live in a zone of their own and sync like any record. Change one on each device to see them agree.")
            }

            Section {
                Picker("Album", selection: $labAlbum) {
                    Text("Choose").tag(Album.ID?.none)
                    ForEach(albums) { Text($0.title).tag(Optional($0.id)) }
                }
                if let id = labAlbum, let album = albums.first(where: { $0.id == id }) {
                    NavigationLink("Open it, edit without saving, then come back") { AlbumDetail(album: album) }
                    labButton("Change the title", id) { $0.title += " (theirs)" }
                    labButton("Add 3 plays", id) { $0.plays += 3 }
                    labButton("Rate it 5 stars", id) { $0.rating = 5 }
                    labButton("Add the tag “lab”", id) { $0.tags.insert("lab") }
                    labButton("Change the label", id) { $0.credits.label += " Records" }
                    labButton("Change the year", id) { $0.year += 1 }
                    labButton("Delete it", id, role: .destructive) { _ in }
                }
            } header: {
                Text("Conflict Lab")
            } footer: {
                Text("Each button saves a change as another device's sync would. Open the album, change the same field without saving, then press a button: plays add, the higher rating wins, tags and credits merge, and a title both changed shows a conflict to settle. Deleting while an edit is open lets the editor bring it back.")
            }

            Section {
                Button("Erase everything on this device", role: .destructive) { confirmingErase = true }
            } footer: {
                Text("Deletes every record in the crate here. With sync, the deletions reach your other devices too.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
        .confirmationDialog("Erase the crate?", isPresented: $confirmingErase) {
            Button("Erase", role: .destructive) { erase() }
        }
    }

    private func labButton(
        _ title: String, _ id: Album.ID, role: ButtonRole? = nil, _ change: @escaping @Sendable (inout Album) -> Void
    ) -> some View {
        Button(title, role: role) {
            Task {
                do {
                    if role == .destructive {
                        try await context.performInBackground { background in
                            try background.delete(record: Album.self, where: #Predicate { $0.id == id })
                        }
                    } else {
                        try await context.editElsewhere(Album.self, id, change)
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            try await context.refresh()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func erase() {
        for type in [Album.self, Artist.self, Genre.self, Playlist.self, Friend.self] as [any Record.Type] {
            delete(type)
        }
        try? context.save()
    }

    private func delete<R: Record>(_ type: R.Type) {
        context.delete(record: type)
    }
}

struct StatusLabel: View {
    var status: RecordContext.Status

    var body: some View {
        switch status {
        case .saved: Label("Up to date", systemImage: "checkmark.icloud").foregroundStyle(.green)
        case .saving: Label("Saving", systemImage: "square.and.arrow.down")
        case .syncing: Label("Syncing", systemImage: "arrow.triangle.2.circlepath.icloud")
        case .offline: Label("Offline", systemImage: "icloud.slash").foregroundStyle(.orange)
        case .signedOut: Label("Not signed in to iCloud", systemImage: "person.crop.circle.badge.xmark").foregroundStyle(.orange)
        case .failed(let error): Label(String(describing: error), systemImage: "exclamationmark.icloud").foregroundStyle(.red)
        }
    }
}
#endif
