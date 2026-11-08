import Foundation
import SwiftRecords
import SyncTestSupport

/// An in-memory stand-in for CloudKit, for an app's own tests. Each container that syncs with it plays one
/// device, so a test can save on one, refresh another and see the change arrive, with no account or network.
///
/// ```swift
/// let cloud = TestCloud()
/// let phone = try RecordContainer(for: [Note.self], syncingWith: cloud)
/// let laptop = try RecordContainer(for: [Note.self], syncingWith: cloud)
/// phone.mainContext.insert(Note(text: "Hi"))
/// try await phone.mainContext.save()      // saves and sends
/// try await laptop.mainContext.refresh()  // fetches the note
/// ```
///
/// It syncs only when a context asks, through the async `save()` and `refresh()`, so a test controls the
/// order of events. Conflicts, merges, deletions and assets behave as they do with CloudKit.
public final class TestCloud: Sendable {
    let server: TestServer

    public init() {
        server = TestServer()
    }

    /// Whether devices can reach the server. Offline, saves stay pending and contexts show `.offline`.
    public var isOnline: Bool {
        get { server.withLock { server.isOnline } }
        set { server.withLock { server.isOnline = newValue } }
    }

    /// The account every device is signed in to, or `nil` for signed out. Each account's records are kept
    /// apart, and a device whose account changes removes the old account's records from itself at its next
    /// sync, as with iCloud.
    public var account: String? {
        get { server.withLock { server.account } }
        set { server.withLock { server.account = newValue } }
    }

    /// Whether the server refuses saves as full, which contexts show as `.failed(.storageFull)`.
    public var isFull: Bool {
        get { server.withLock { server.isFull } }
        set { server.withLock { server.isFull = newValue } }
    }

    /// How many records the server holds, deletions left out.
    public var recordCount: Int { server.count }

    /// Deletes every zone on the server, as when someone deletes the app's iCloud data. Devices start over
    /// at their next sync.
    public func eraseAll() {
        server.reset()
    }
}

extension RecordContainer {
    /// Opens a container that syncs with `cloud`, as one device. It lives in memory unless `location` says
    /// otherwise.
    public convenience init(
        for types: [any Record.Type],
        location: Location = .inMemory,
        initialZone: Zone = .default,
        syncingWith cloud: TestCloud
    ) throws {
        try self.init(
            for: types, location: location, initialZone: initialZone,
            syncProvider: TestProvider(server: cloud.server)
        )
    }
}
