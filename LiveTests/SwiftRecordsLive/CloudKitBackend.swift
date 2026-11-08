import CloudKit
import Foundation
import SwiftRecords

/// Runs the scenarios on CloudKit's development environment. Each device is its own container with its
/// own store and sync engine, on the Mac's iCloud account, as Apple suggests for testing `CKSyncEngine`.
/// Engines sync only when a context asks, so a scenario controls the order of events.
@MainActor
final class CloudKitBackend: SyncBackend {
    /// Every zone the live app makes starts with this, so a run can sweep up what a crashed one left.
    static let zonePrefix = "swiftrecords-live-"

    let name = "CloudKit"
    let canGoOffline = false
    let attempts = 15
    let pause = Duration.seconds(1)

    let container = CKContainer.default()
    private let root = FileManager.default.temporaryDirectory.appending(path: "SwiftRecordsLive-\(UUID().uuidString)")
    /// The devices of the scenario running now, kept open until it ends.
    private var devices: [RecordContainer] = []

    func makeDevice(_ types: [any Record.Type], zone: Zone) throws -> RecordContainer {
        let device = try RecordContainer(
            for: types, location: .directory(root.appending(path: UUID().uuidString)), initialZone: zone,
            sync: CloudKitOptions(syncsSharedDatabase: false, automaticallySync: false)
        )
        devices.append(device)
        return device
    }

    func freshZone() throws -> Zone {
        try Zone(Self.zonePrefix + UUID().uuidString.prefix(8).lowercased())
    }

    func setOnline(_ online: Bool) {}

    func cleanUp(_ zone: Zone) async {
        devices.removeAll()
        _ = try? await container.privateCloudDatabase.deleteRecordZone(withID: CKRecordZone.ID(zoneName: zone.name))
        try? FileManager.default.removeItem(at: root)
    }

    /// Deletes the zones earlier runs left behind, such as after a crash. Returns how many it deleted.
    func sweep() async throws -> Int {
        let zones = try await container.privateCloudDatabase.allRecordZones()
            .map(\.zoneID)
            .filter { $0.zoneName.hasPrefix(Self.zonePrefix) }
        guard !zones.isEmpty else { return 0 }
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: zones)
        return zones.count
    }
}
