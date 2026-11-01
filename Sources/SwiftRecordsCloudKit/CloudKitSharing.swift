#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftRecords

/// Sharing with zone-wide `CKShare`s: one share per zone, saved in the owner's private database. People who
/// accept it see the zone in their shared database, which the provider's second engine syncs.
///
/// Invite people with the system's sharing interface, built from `ckShare(for:)` and `ckContainer`, such
/// as `UICloudSharingController(share:container:)`. The app accepts in its scene delegate's
/// `windowScene(_:userDidAcceptCloudKitShareWith:)` by passing the metadata to
/// `RecordContainer.acceptShare(_:)`.
extension CloudKitSyncProvider: ZoneSharing {
    public func share(_ zone: Zone) async throws -> ZoneShare {
        try await ZoneShare(ckShare(for: zone), zone: zone)
    }

    /// The zone's `CKShare`, saved first when it has none, for the system's sharing interface.
    public func ckShare(for zone: Zone) async throws -> CKShare {
        guard zone.scope == .private else { throw RecordsError.sharingUnavailable(zone: zone.description) }
        if let existing = try await fetchShare(for: zone) {
            return existing
        }
        let share = CKShare(recordZoneID: Self.zoneID(zone))
        share[CKShare.SystemFieldKey.title] = zone.name as NSString
        share.publicPermission = linkPermission
        do {
            let (saved, _) = try await ckContainer.privateCloudDatabase.modifyRecords(saving: [share], deleting: [])
            guard let result = saved[share.recordID], let stored = try result.get() as? CKShare else {
                throw SyncFailure.other("CloudKit didn't return the saved share")
            }
            return stored
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device shared it first.
            if let existing = try await fetchShare(for: zone) { return existing }
            throw Self.failure(error)
        } catch let error as CKError {
            throw Self.failure(error)
        }
    }

    public func existingShare(for zone: Zone) async throws -> ZoneShare? {
        try await fetchShare(for: zone).map { ZoneShare($0, zone: zone) }
    }

    public func acceptShare(_ invitation: URL) async throws -> Zone {
        let metadata: CKShare.Metadata
        do {
            metadata = try await ckContainer.shareMetadata(for: invitation)
        } catch {
            throw Self.failure(error)
        }
        return try await accept(metadata)
    }

    /// Accepts a share the system handed the app, and returns its zone as the person now sees it.
    public func accept(_ metadata: CKShare.Metadata) async throws -> Zone {
        let zoneID = metadata.share.recordID.zoneID
        guard let zone = Self.zone(for: zoneID, scope: .shared) else {
            throw RecordsError.sharingUnavailable(zone: zoneID.zoneName)
        }
        if metadata.participantStatus != .accepted {
            do {
                _ = try await ckContainer.accept(metadata)
            } catch {
                throw Self.failure(error)
            }
        }
        return zone
    }

    public func stopSharing(_ zone: Zone) async throws {
        // The owner deletes the share. A participant deletes their copy in the shared database, which
        // takes them out of it.
        let database = zone.scope == .shared ? ckContainer.sharedCloudDatabase : ckContainer.privateCloudDatabase
        do {
            let (_, deleted) = try await database.modifyRecords(saving: [], deleting: [Self.shareID(for: zone)])
            for result in deleted.values {
                try result.get()
            }
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch {
            throw Self.failure(error)
        }
    }

    private func fetchShare(for zone: Zone) async throws -> CKShare? {
        let database = zone.scope == .shared ? ckContainer.sharedCloudDatabase : ckContainer.privateCloudDatabase
        do {
            return try await database.record(for: Self.shareID(for: zone)) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        } catch {
            throw Self.failure(error)
        }
    }

    private static func shareID(for zone: Zone) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
    }
}

extension ZoneShare {
    init(_ share: CKShare, zone: Zone) {
        let participants = share.participants.map(ShareParticipant.init)
        self.init(
            zone: zone, url: share.url,
            participants: participants.filter { $0.role == .owner } + participants.filter { $0.role != .owner }
        )
    }
}

extension ShareParticipant {
    init(_ participant: CKShare.Participant) {
        let identity = participant.userIdentity
        let name = identity.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        let id = identity.userRecordID?.recordName ?? identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber ?? ""
        let status: Status = switch participant.acceptanceStatus {
        case .accepted: .accepted
        case .removed: .removed
        default: .pending
        }
        self.init(id: id, name: name ?? identity.lookupInfo?.emailAddress, role: participant.role == .owner ? .owner : .participant, status: status)
    }
}

extension RecordContainer {
    /// Accepts a share the system handed the app, from `windowScene(_:userDidAcceptCloudKitShareWith:)`
    /// or `application(_:userDidAcceptCloudKitShareWith:)`, and fetches its records. Returns the zone for a
    /// context to show.
    public func acceptShare(_ metadata: CKShare.Metadata) async throws -> Zone {
        guard let provider = syncProvider as? CloudKitSyncProvider else {
            throw RecordsError.sharingUnavailable(zone: metadata.share.recordID.zoneID.zoneName)
        }
        let zone = try await provider.accept(metadata)
        try await joined(zone)
        return zone
    }
}
#endif
