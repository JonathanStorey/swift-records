import CrateModels
import CrateUI
import SwiftUI

/// Crate syncs through the app's default CloudKit container, the first one its entitlements list:
/// `iCloud.<bundle identifier>`.
@main
struct CrateApp: App {
    let container: RecordContainer

    init() {
        do {
            container = try RecordContainer(for: crateTypes, sync: .cloudKit)
        } catch {
            fatalError("Crate couldn't open its records: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            CrateRootView()
                .recordContainer(container)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 760)
        #endif
    }
}
