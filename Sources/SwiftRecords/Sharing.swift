import Foundation

/// Sharing whole zones with other people, through a sync provider that can.
///
/// ```swift
/// let share = try await container.share("family")        // send share.url to the people you invite
/// let zone = try await container.acceptShare(link)        // on their device: Zone("family", sharedBy: …)
/// context.zone = zone                                      // their views now show and edit it
/// ```
///
/// Everyone with the zone syncs it as they would their own. When the owner stops sharing, participants lose
/// the zone and its records leave their devices, and the owner keeps it. A participant who leaves loses it
/// too.
extension RecordContainer {
    /// Shares one of the person's own zones, or returns its share when it already has one. The zone's
    /// pending changes go to the server first, so people who accept find its records there. Throws
    /// `RecordsError.sharingUnavailable` for a zone that doesn't sync or that someone else owns, or when
    /// the sync provider can't share.
    public func share(_ zone: Zone) async throws -> ZoneShare {
        guard zone.scope == .private else { throw RecordsError.sharingUnavailable(zone: zone.description) }
        let sharing = try sharing(for: zone)
        if let sync = try storage(for: zone).sync {
            await sync.send()
        }
        return try await sharing.share(zone)
    }

    /// The zone's share and who is in it, or `nil` when it isn't shared. For a zone shared with the person,
    /// the owner's share.
    public func existingShare(for zone: Zone) async throws -> ZoneShare? {
        try await sharing(for: zone).existingShare(for: zone)
    }

    /// Joins the zone an invitation from `share(_:)` shares and fetches its records. Returns the zone, in
    /// the `.shared` scope, for a context to show: `context.zone = zone`.
    public func acceptShare(_ invitation: URL) async throws -> Zone {
        guard let sharing = syncHub?.provider.sharing else { throw RecordsError.sharingUnavailable(zone: invitation.absoluteString) }
        let zone = try await sharing.acceptShare(invitation)
        try await joined(zone)
        return zone
    }

    /// Notes a zone the person just joined and fetches its records. A provider with its own way to accept,
    /// such as CloudKit's share metadata, calls it after accepting.
    package func joined(_ zone: Zone) async throws {
        guard let hub = syncHub, let sync = syncedStorage(for: zone)?.sync else {
            throw RecordsError.sharingUnavailable(zone: zone.description)
        }
        await hub.updateSharedZones(adding: [zone], removing: [])
        try await sync.refresh()
    }

    /// Stops sharing one of the person's own zones, which they keep and every participant loses. For a zone
    /// shared with the person, leaves it, and its records leave this device.
    public func stopSharing(_ zone: Zone) async throws {
        try await sharing(for: zone).stopSharing(zone)
        if zone.scope == .shared {
            await syncHub?.updateSharedZones(adding: [], removing: [zone])
            try await MainActor.run { try deleteAllData(in: zone) }
        }
    }

    /// The zones others shared with the person, by owner, then name: those accepted here, and those the
    /// server has listed since, as when the person accepted on another device. A zone leaves the list when
    /// its owner stops sharing it or the person leaves it.
    public func sharedZones() async -> [Zone] {
        await syncHub?.sharedZones ?? []
    }

    /// The sync provider, for a provider's own additions to the container.
    package var syncProvider: (any SyncProvider)? { syncHub?.provider }

    private func sharing(for zone: Zone) throws -> any ZoneSharing {
        guard let sharing = syncHub?.provider.sharing, let storage = syncedStorage(for: zone), storage.sync != nil else {
            throw RecordsError.sharingUnavailable(zone: zone.description)
        }
        return sharing
    }
}
