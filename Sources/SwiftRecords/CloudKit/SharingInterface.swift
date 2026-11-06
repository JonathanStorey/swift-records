#if canImport(CloudKit) && (os(iOS) || os(macOS) || os(visionOS))
import CloudKit
import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The system's sharing interface, without CloudKit types: `shareItem(for:)` feeds SwiftUI's `ShareLink`,
// `RecordsAppDelegate` accepts invitations, and `onShareAccepted(perform:)` hands the joined zone to a view.

extension RecordContainer {
    /// A zone to share through SwiftUI's `ShareLink`, which shows the system's interface: inviting people
    /// the first time, and managing who is in the share after. It looks up the zone's share, so make it
    /// in a task and make it again after the share changes.
    ///
    /// ```swift
    /// @State private var item: ZoneShareItem?
    ///
    /// if let item { ShareLink(item: item, preview: SharePreview("Family recipes")) }
    /// …
    /// .task { item = try? await container.shareItem(for: "family") }
    /// ```
    ///
    /// The zone's pending changes go to the server before a new share does, so people who accept find its
    /// records there. Only the person's own zones can be shared. Throws `RecordsError.sharingUnavailable`
    /// for a zone that can't be shared.
    public func shareItem(for zone: Zone) async throws -> ZoneShareItem {
        guard zone.scope == .private, let provider = cloudKitProvider, provider.sharing != nil else {
            throw RecordsError.sharingUnavailable(zone: zone.description)
        }
        let existing = try await provider.fetchShare(for: zone)
        return ZoneShareItem(zone: zone, container: self, existing: existing.map(ZoneShareItem.Existing.init))
    }

    /// The zone's `CKShare`, saved first when it has none, after sending the zone's pending changes.
    func ckShare(for zone: Zone) async throws -> CKShare {
        guard zone.scope == .private, let provider = cloudKitProvider, provider.sharing != nil else {
            throw RecordsError.sharingUnavailable(zone: zone.description)
        }
        if let sync = try storage(for: zone).sync {
            await sync.send()
        }
        return try await provider.ckShare(for: zone)
    }
}

/// A zone to share with `ShareLink`. Make one with `RecordContainer.shareItem(for:)`.
public struct ZoneShareItem: Transferable, Sendable {
    /// The zone being shared.
    public let zone: Zone
    let container: RecordContainer
    /// The zone's share when it already had one, which the system's interface then manages.
    let existing: Existing?

    /// A saved share, only read after it's fetched.
    struct Existing: @unchecked Sendable {
        let share: CKShare
    }

    /// Whether the zone was already shared when the item was made.
    public var isShared: Bool { existing != nil }

    public static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            item.exportedShare()
        }
    }

    private func exportedShare() -> CKShareTransferRepresentation<ZoneShareItem>.ExportedShare {
        let ckContainer = container.cloudKitProvider?.ckContainer ?? .default()
        if let existing {
            return .existing(existing.share, container: ckContainer)
        }
        let container = container
        let zone = zone
        return .prepareShare(container: ckContainer) {
            try await container.ckShare(for: zone)
        }
    }
}

// MARK: - Accepting

extension RecordContainer {
    /// Accepts an invitation the system handed the app into the open container that syncs with its CloudKit
    /// container, and tells `onShareAccepted(perform:)` how it went.
    static func accept(_ metadata: CKShare.Metadata) {
        let invitation = Invitation(metadata: metadata)
        Task {
            let result: Result<Zone, any Error>
            if let container = syncing.container(for: invitation.metadata.containerIdentifier) {
                do {
                    result = .success(try await container.acceptShare(invitation.metadata))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(RecordsError.sharingUnavailable(zone: invitation.metadata.share.recordID.zoneID.zoneName))
            }
            await ShareAcceptances.shared.deliver(result)
        }
    }

    /// The system's share metadata, carried into the task that accepts it.
    private struct Invitation: @unchecked Sendable {
        let metadata: CKShare.Metadata
    }
}

/// Accepted shares not yet handed to a view, so one accepted as the app launches waits for the first view
/// that asks.
@MainActor
final class ShareAcceptances {
    static let shared = ShareAcceptances()
    static let notification = Notification.Name("SwiftRecords.shareAccepted")

    private var undelivered: [Result<Zone, any Error>] = []

    func deliver(_ result: Result<Zone, any Error>) {
        undelivered.append(result)
        NotificationCenter.default.post(name: Self.notification, object: nil)
    }

    func take() -> [Result<Zone, any Error>] {
        defer { undelivered.removeAll() }
        return undelivered
    }
}

extension View {
    /// Runs `action` with the zone the person joined each time they accept an invitation, or with the
    /// error when joining failed. Needs `RecordsAppDelegate`.
    ///
    /// ```swift
    /// ContentView()
    ///     .onShareAccepted { result in
    ///         if case .success(let zone) = result { context.zone = zone }
    ///     }
    /// ```
    public func onShareAccepted(perform action: @escaping @MainActor (Result<Zone, any Error>) -> Void) -> some View {
        modifier(ShareAcceptedModifier(action: action))
    }
}

private struct ShareAcceptedModifier: ViewModifier {
    let action: @MainActor (Result<Zone, any Error>) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { deliver() }
            .onReceive(NotificationCenter.default.publisher(for: ShareAcceptances.notification)) { _ in deliver() }
    }

    @MainActor
    private func deliver() {
        for result in ShareAcceptances.shared.take() {
            action(result)
        }
    }
}

// MARK: - App delegate

#if canImport(UIKit)

/// Accepts the invitations people tap, for every container that syncs with CloudKit. Add it to the app
/// and handle the joined zone with `onShareAccepted(perform:)`:
///
/// ```swift
/// @main struct RecipesApp: App {
///     @UIApplicationDelegateAdaptor(RecordsAppDelegate.self) private var appDelegate
///     …
/// }
/// ```
///
/// Subclass it to add your own delegate methods.
open class RecordsAppDelegate: NSObject, UIApplicationDelegate {
    open func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = RecordsSceneDelegate.self
        return configuration
    }
}

/// The scene delegate `RecordsAppDelegate` installs, which iOS hands invitations to.
final class RecordsSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // An invitation that launched the app.
        if let metadata = connectionOptions.cloudKitShareMetadata {
            RecordContainer.accept(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        RecordContainer.accept(cloudKitShareMetadata)
    }
}
#else

/// Accepts the invitations people open, for every container that syncs with CloudKit. Add it to the app
/// and handle the joined zone with `onShareAccepted(perform:)`:
///
/// ```swift
/// @main struct RecipesApp: App {
///     @NSApplicationDelegateAdaptor(RecordsAppDelegate.self) private var appDelegate
///     …
/// }
/// ```
///
/// Subclass it to add your own delegate methods.
open class RecordsAppDelegate: NSObject, NSApplicationDelegate {
    open func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        RecordContainer.accept(metadata)
    }
}
#endif
#endif
