#if canImport(CloudKit)
import CloudKit
import Foundation

/// How a container syncs with CloudKit.
///
/// ```swift
/// let records = try RecordContainer(for: [Recipe.self], cloudKit: .container("iCloud.com.example.app"))
/// ```
///
/// The app needs the iCloud capability with CloudKit on, and Background Modes with remote notifications,
/// so pushes start fetches. The container checks both as it opens. A missing capability or a container
/// CloudKit doesn't know logs the Xcode steps to fix it and shows in `status` as
/// `.failed(.syncNotConfigured(problem:fix:))`, and a missing background mode logs a warning.
public struct CloudKitOptions: Sendable, Hashable {
    /// The CloudKit container, such as `"iCloud.com.example.app"`. `nil` uses the app's default container.
    public var containerIdentifier: String?
    /// Whether zones others shared with the person sync too, through the shared database. Sharing needs it.
    public var syncsSharedDatabase: Bool
    /// What someone who opens a share's link may do without being invited. `.none` admits only the people
    /// invited through the system's sharing interface.
    public var linkPermission: CKShare.ParticipantPermission
    /// Whether CloudKit sends and fetches on its own. Turn it off to sync only when a context asks.
    public var automaticallySync: Bool

    public init(
        containerIdentifier: String? = nil, syncsSharedDatabase: Bool = true,
        linkPermission: CKShare.ParticipantPermission = .none, automaticallySync: Bool = true
    ) {
        self.containerIdentifier = containerIdentifier
        self.syncsSharedDatabase = syncsSharedDatabase
        self.linkPermission = linkPermission
        self.automaticallySync = automaticallySync
    }

    /// The app's default CloudKit container.
    public static var `default`: CloudKitOptions { CloudKitOptions() }

    /// A CloudKit container by its identifier.
    public static func container(_ identifier: String) -> CloudKitOptions {
        CloudKitOptions(containerIdentifier: identifier)
    }
}

extension RecordContainer {
    /// Opens a container whose zones sync with CloudKit, or stay on the device when `cloudKit` is `nil`.
    ///
    /// Every zone syncs except `.inMemory`, `.localOnly` and any `Zone.local(_:)`. The CloudKit container
    /// stays fixed for the container's life.
    public convenience init(
        for types: [any Record.Type] = [],
        location: Location = .applicationSupport,
        initialZone: Zone = .default,
        cloudKit: CloudKitOptions?
    ) throws {
        try self.init(
            for: types, location: location, initialZone: initialZone,
            syncProvider: cloudKit.map(CloudKitSyncProvider.init(options:))
        )
    }

    /// The CloudKit container the records sync with, or `nil` for a container that doesn't, as for
    /// `UICloudSharingController(share:container:)`.
    public var ckContainer: CKContainer? {
        (syncProvider as? CloudKitSyncProvider)?.ckContainer
    }

    /// The zone's `CKShare`, saved first when it has none, for the system's sharing interface. The zone's
    /// pending changes go to the server first, so people who accept find its records there.
    public func ckShare(for zone: Zone) async throws -> CKShare {
        guard zone.scope == .private, let provider = syncProvider as? CloudKitSyncProvider, provider.sharing != nil else {
            throw RecordsError.sharingUnavailable(zone: zone.description)
        }
        if let sync = try storage(for: zone).sync {
            await sync.send()
        }
        return try await provider.ckShare(for: zone)
    }
}

extension CloudKitSyncProvider {
    convenience init(options: CloudKitOptions) {
        self.init(
            container: options.containerIdentifier.map(CKContainer.init(identifier:)) ?? .default(),
            sharedDatabase: options.syncsSharedDatabase, linkPermission: options.linkPermission,
            automaticallySync: options.automaticallySync
        )
    }
}
#endif
