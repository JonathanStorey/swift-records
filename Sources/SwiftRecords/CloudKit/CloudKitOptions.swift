#if canImport(CloudKit)
import CloudKit
import Foundation

/// How a container syncs with CloudKit.
///
/// ```swift
/// let container = try RecordContainer(for: Recipe.self, Step.self, sync: .cloudKit)
/// let container = try RecordContainer(for: Recipe.self, sync: .cloudKit("iCloud.com.example.app"))
/// ```
///
/// The app needs the iCloud capability with CloudKit on, and Background Modes with remote notifications,
/// so pushes start fetches. The container checks both as it opens. A missing capability or a container
/// CloudKit doesn't know logs the Xcode steps to fix it and shows in `status` as
/// `.failed(.syncNotConfigured(problem:fix:))`, and a missing background mode logs a warning.
public struct CloudKitOptions: Sendable, Hashable {
    /// The CloudKit container, such as `"iCloud.com.example.app"`. `nil` uses the app's default container.
    public var containerIdentifier: String?
    /// Who may join a zone you share by opening its link.
    public var sharing: ShareAccess
    /// Whether zones others shared with the person sync too. Sharing needs it.
    public var syncsSharedDatabase: Bool
    /// Whether CloudKit sends and fetches on its own. Turn it off to sync only when a context asks.
    public var automaticallySync: Bool

    public init(
        containerIdentifier: String? = nil, sharing: ShareAccess = .invitedOnly, syncsSharedDatabase: Bool = true,
        automaticallySync: Bool = true
    ) {
        self.containerIdentifier = containerIdentifier
        self.sharing = sharing
        self.syncsSharedDatabase = syncsSharedDatabase
        self.automaticallySync = automaticallySync
    }

    /// Syncs with the app's default CloudKit container.
    public static var cloudKit: CloudKitOptions { CloudKitOptions() }

    /// Syncs with a CloudKit container by its identifier, or the app's default one for `nil`.
    public static func cloudKit(_ containerIdentifier: String? = nil, sharing: ShareAccess = .invitedOnly) -> CloudKitOptions {
        CloudKitOptions(containerIdentifier: containerIdentifier, sharing: sharing)
    }
}

/// Who may join a shared zone by opening its link.
public enum ShareAccess: Sendable, Hashable {
    /// Only the people invited through the system's sharing interface. The default.
    case invitedOnly
    /// Anyone with the link joins and can read the zone.
    case anyoneWithLinkCanView
    /// Anyone with the link joins and can edit the zone.
    case anyoneWithLinkCanEdit

    var permission: CKShare.ParticipantPermission {
        switch self {
        case .invitedOnly: .none
        case .anyoneWithLinkCanView: .readOnly
        case .anyoneWithLinkCanEdit: .readWrite
        }
    }
}

extension RecordContainer {
    /// Opens a container whose zones sync with CloudKit, or stay on the device when `sync` is `nil`.
    ///
    /// Every zone syncs except `.inMemory`, `.localOnly` and any `Zone.local(_:)`. The CloudKit container
    /// stays fixed for the container's life.
    public convenience init(
        for types: [any Record.Type] = [],
        location: Location = .applicationSupport,
        initialZone: Zone = .default,
        sync: CloudKitOptions?
    ) throws {
        try self.init(
            for: types, location: location, initialZone: initialZone,
            syncProvider: sync.map(CloudKitSyncProvider.init(options:))
        )
        if sync != nil {
            Self.syncing.add(self)
        }
    }

    /// Opens a container for these record types whose zones sync with CloudKit, or stay on the device when
    /// `sync` is `nil`, as SwiftData's `ModelContainer(for:)` takes its models.
    public convenience init(
        for type: any Record.Type,
        _ more: any Record.Type...,
        location: Location = .applicationSupport,
        initialZone: Zone = .default,
        sync: CloudKitOptions?
    ) throws {
        try self.init(for: [type] + more, location: location, initialZone: initialZone, sync: sync)
    }

    /// The CloudKit provider, or `nil` for a container that doesn't sync.
    var cloudKitProvider: CloudKitSyncProvider? {
        syncProvider as? CloudKitSyncProvider
    }

    /// The open containers that sync with CloudKit, held weakly, for the app delegate to accept shares into.
    static let syncing = WeakContainers()

    final class WeakContainers: @unchecked Sendable {
        private struct Entry {
            weak var container: RecordContainer?
        }

        private let lock = NSLock()
        private var entries: [Entry] = []

        func add(_ container: RecordContainer) {
            lock.withLock {
                entries.removeAll { $0.container == nil }
                entries.append(Entry(container: container))
            }
        }

        /// The open container syncing with this CloudKit container, the first opened when several do.
        func container(for identifier: String) -> RecordContainer? {
            lock.withLock {
                entries.lazy.compactMap(\.container).first { $0.cloudKitProvider?.ckContainer.containerIdentifier == identifier }
            }
        }
    }
}

extension CloudKitSyncProvider {
    convenience init(options: CloudKitOptions) {
        self.init(
            container: options.containerIdentifier.map(CKContainer.init(identifier:)) ?? .default(),
            sharedDatabase: options.syncsSharedDatabase, linkPermission: options.sharing.permission,
            automaticallySync: options.automaticallySync
        )
    }
}
#endif
