#if canImport(SwiftUI)
import CrateModels
import SwiftUI

/// The whole app: give it a container with `.recordContainer(_:)`.
public struct CrateRootView: View {
    @Environment(\.recordContext) private var context
    @RecordStorage private var settings = CrateSettings()

    public init() {}

    public var body: some View {
        TabView {
            Tab("Albums", systemImage: "opticaldisc") {
                NavigationStack { AlbumList(order: settings.albumOrder).id(settings.albumOrder) }
            }
            Tab("Artists", systemImage: "music.mic") {
                NavigationStack { ArtistList() }
            }
            Tab("Genres", systemImage: "guitars") {
                NavigationStack { GenreList() }
            }
            Tab("Playlists", systemImage: "music.note.list") {
                NavigationStack { PlaylistList() }
            }
            Tab("Loans", systemImage: "person.2") {
                NavigationStack { LoanList() }
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") {
                NavigationStack { SyncView() }
            }
        }
        .onChange(of: settings.autosaveDelay, initial: true) { _, delay in
            context.autosave = delay == 0 ? .whenInactive : .after(.seconds(delay))
        }
    }
}
#endif
