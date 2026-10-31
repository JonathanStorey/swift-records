#if canImport(CloudKit)
import CloudKit
import Foundation
import SwiftRecords

/// Syncs with CloudKit through `CKSyncEngine`: the first-class provider.
///
/// One engine serves the private database and, unless you turn it off, another serves the shared one.
/// The engines do the scheduling, pushes, retries, batching and account tracking. This class only
/// translates: zones to `CKRecordZone.ID`s, records to `CKRecord`s, and the engines' events to `SyncEvent`s
/// for the container.
///
/// ```swift
/// let provider = CloudKitSyncProvider(container: CKContainer(identifier: "iCloud.com.example.app"))
/// let records = try RecordContainer(for: [Recipe.self], syncProvider: provider)
/// ```
///
/// The app needs the iCloud capability with CloudKit on, and Background Modes with remote notifications,
/// so pushes start fetches. A field-level change sets only its changed keys on the `CKRecord`, built on
/// the server copy's system fields, so an unchanged asset or long field never uploads again. Asset files
/// travel inside their records as `CKAsset`s and land as the records do, with no separate transfer.
public final class CloudKitSyncProvider: SyncProvider, CKSyncEngineDelegate, @unchecked Sendable {
    public let ckContainer: CKContainer
    public let scopes: Set<Zone.Scope>
    private let automaticallySync: Bool

    private let lock = NSLock()
    private var engines: [Zone.Scope: CKSyncEngine] = [:]
    private weak var delegate: (any SyncDelegate)?
    private weak var container: RecordContainer?
    /// Private zones this launch has asked the server to create.
    private var createdZones: Set<Zone> = []
    /// How many fetches the container started, so the engines' fetch events can say they were manual.
    private var manualFetches = 0

    /// - Parameters:
    ///   - container: The CloudKit container, `CKContainer.default()` unless the app uses another.
    ///   - sharedDatabase: Whether to sync zones others shared with the person, through a second engine.
    ///   - automaticallySync: Whether the engines send and fetch on their own. Turn it off in tests.
    public init(container: CKContainer = .default(), sharedDatabase: Bool = true, automaticallySync: Bool = true) {
        ckContainer = container
        scopes = sharedDatabase ? [.private, .shared] : [.private]
        self.automaticallySync = automaticallySync
    }

    public var identifier: String { "cloudkit:\(ckContainer.containerIdentifier ?? "default")" }

    public func attach(_ container: RecordContainer) {
        lock.withLock { self.container = container }
    }

    // MARK: SyncProvider

    public func start(_ scope: Zone.Scope, state: Data?, delegate: any SyncDelegate) async {
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let database = scope == .shared ? ckContainer.sharedCloudDatabase : ckContainer.privateCloudDatabase
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: self)
        configuration.automaticallySync = automaticallySync
        let engine = CKSyncEngine(configuration)
        lock.withLock {
            self.delegate = delegate
            engines[scope] = engine
        }
    }

    public func addPending(_ changes: [PendingRecordChange]) {
        // A private zone exists on the server only once created, so each one is created before its records.
        let newZones = lock.withLock {
            let zones = Set(changes.map(\.zone)).filter { $0.scope == .private && !createdZones.contains($0) }
            createdZones.formUnion(zones)
            return zones
        }
        if !newZones.isEmpty {
            addPending(newZones.sorted { $0.name < $1.name }.map { PendingZoneChange.save($0) })
        }
        for (scope, group) in Dictionary(grouping: changes, by: \.zone.scope) {
            engine(scope)?.state.add(pendingRecordZoneChanges: group.map(Self.pendingChange))
        }
    }

    public func removePending(_ changes: [PendingRecordChange]) {
        for (scope, group) in Dictionary(grouping: changes, by: \.zone.scope) {
            engine(scope)?.state.remove(pendingRecordZoneChanges: group.map(Self.pendingChange))
        }
    }

    public func addPending(_ changes: [PendingZoneChange]) {
        // Only the owner creates or deletes a zone, so the shared database takes none.
        let changes = changes.filter { $0.zone.scope == .private }
        guard !changes.isEmpty else { return }
        engine(.private)?.state.add(pendingDatabaseChanges: changes.map(Self.databaseChange))
    }

    public func removePending(_ changes: [PendingZoneChange]) {
        let changes = changes.filter { $0.zone.scope == .private }
        guard !changes.isEmpty else { return }
        engine(.private)?.state.remove(pendingDatabaseChanges: changes.map(Self.databaseChange))
    }

    public func sendChanges(_ options: SendOptions) async throws {
        for (scope, engine) in allEngines {
            guard let ckOptions = Self.sendOptions(options, scope: scope) else { continue }
            do {
                try await engine.sendChanges(ckOptions)
            } catch {
                throw Self.failure(error)
            }
        }
    }

    public func fetchChanges(_ options: FetchOptions) async throws {
        lock.withLock { manualFetches += 1 }
        defer { lock.withLock { manualFetches -= 1 } }
        for (scope, engine) in allEngines {
            guard var ckOptions = Self.fetchOptions(options.scope, scope: scope) else { continue }
            ckOptions.prioritizedZoneIDs = options.prioritizedZones.filter { $0.scope == scope }.map(Self.zoneID)
            do {
                try await engine.fetchChanges(ckOptions)
            } catch {
                throw Self.failure(error)
            }
        }
    }

    public func cancelOperations() async {
        for (_, engine) in allEngines {
            await engine.cancelOperations()
        }
    }

    private func engine(_ scope: Zone.Scope) -> CKSyncEngine? {
        lock.withLock { engines[scope] }
    }

    /// The engines, private first.
    private var allEngines: [(Zone.Scope, CKSyncEngine)] {
        lock.withLock { engines.sorted { $0.key == .private && $1.key != .private } }
    }

    private func scope(of engine: CKSyncEngine) -> Zone.Scope {
        lock.withLock { engines.first { $0.value === engine }?.key } ?? .private
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let delegate = lock.withLock({ delegate }) else { return }
        let scope = scope(of: syncEngine)
        for event in events(for: event, scope: scope) {
            await delegate.handle(event)
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let delegate = lock.withLock({ delegate }), let container = lock.withLock({ self.container }) else { return nil }
        let scope = scope(of: syncEngine)
        let options = SendOptions(scope: Self.changeScope(context.options.scope, scope: scope))
        guard let batch = await delegate.nextBatch(SendContext(reason: Self.reason(context.reason), options: options)) else {
            return nil
        }
        var saves: [CKRecord] = []
        for change in batch.saves where change.zone.scope == scope {
            if let record = try? container.ckRecord(for: change, in: Self.zoneID(change.zone)) {
                saves.append(record)
            }
        }
        let deletes = batch.deletes.filter { $0.zone.scope == scope }.map {
            RecordContainer.recordID(for: $0.id, in: Self.zoneID($0.zone))
        }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saves, recordIDsToDelete: deletes, atomicByZone: batch.atomicByZone)
    }

    public func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        guard let delegate = lock.withLock({ delegate }) else { return context.options }
        let scope = scope(of: syncEngine)
        let options = FetchOptions(
            scope: Self.changeScope(context.options.scope, scope: scope),
            prioritizedZones: context.options.prioritizedZoneIDs.compactMap { Self.zone(for: $0, scope: scope) }
        )
        let chosen = await delegate.nextFetchOptions(FetchContext(reason: Self.reason(context.reason), options: options))
        var result = context.options
        result.prioritizedZoneIDs = chosen.prioritizedZones.filter { $0.scope == scope }.map(Self.zoneID)
        return result
    }

    // MARK: Events

    private func events(for event: CKSyncEngine.Event, scope: Zone.Scope) -> [SyncEvent] {
        switch event {
        case .stateUpdate(let update):
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else { return [] }
            return [.stateUpdate(scope, data)]

        case .accountChange(let change):
            // Both engines report the same account. The private one speaks for it.
            guard scope == .private else { return [] }
            switch change.changeType {
            case .signIn(let user):
                return [.accountChange(.signIn(user: user.recordName))]
            case .signOut(let previous):
                return [.accountChange(.signOut(previousUser: previous.recordName))]
            case .switchAccounts(let previous, let current):
                return [.accountChange(.switchAccounts(from: previous.recordName, to: current.recordName))]
            @unknown default:
                return []
            }

        case .fetchedDatabaseChanges(let changes):
            let modified = changes.modifications.compactMap { Self.zone(for: $0.zoneID, scope: scope) }
            let deleted = changes.deletions.compactMap { deletion -> ZoneDeletion? in
                guard let zone = Self.zone(for: deletion.zoneID, scope: scope) else { return nil }
                switch deletion.reason {
                case .deleted: return ZoneDeletion(zone: zone, reason: .deleted)
                case .purged: return ZoneDeletion(zone: zone, reason: .purged)
                case .encryptedDataReset: return ZoneDeletion(zone: zone, reason: .encryptedDataReset)
                @unknown default: return nil
                }
            }
            return [.fetchedZoneChanges(modified: modified, deleted: deleted)]

        case .fetchedRecordZoneChanges(let changes):
            let saved = changes.modifications.compactMap { received($0.record, scope: scope) }
            let deleted = changes.deletions.compactMap { deletion -> RecordDeletion? in
                guard let zone = Self.zone(for: deletion.recordID.zoneID, scope: scope),
                      let id = UUID(uuidString: deletion.recordID.recordName) else { return nil }
                return RecordDeletion(id: id, zone: zone, type: deletion.recordType)
            }
            return [.fetchedRecordChanges(saved: saved, deleted: deleted)]

        case .sentDatabaseChanges(let changes):
            var result = SentZoneChanges()
            result.saved = changes.savedZones.compactMap { Self.zone(for: $0.zoneID, scope: scope) }
            result.deleted = changes.deletedZoneIDs.compactMap { Self.zone(for: $0, scope: scope) }
            for failure in changes.failedZoneSaves {
                guard let zone = Self.zone(for: failure.zone.zoneID, scope: scope) else { continue }
                result.failed.append(FailedZoneChange(zone: zone, failure: Self.failure(failure.error)))
                // A zone that didn't save is created again with the next send.
                lock.withLock { _ = createdZones.remove(zone) }
            }
            for (zoneID, error) in changes.failedZoneDeletes {
                guard let zone = Self.zone(for: zoneID, scope: scope) else { continue }
                result.failed.append(FailedZoneChange(zone: zone, failure: Self.failure(error)))
            }
            return [.sentZoneChanges(result)]

        case .sentRecordZoneChanges(let changes):
            var result = SentRecordChanges()
            result.saved = changes.savedRecords.compactMap { Self.acknowledged($0, scope: scope) }
            for failure in changes.failedRecordSaves {
                guard var change = Self.acknowledged(failure.record, scope: scope) else { continue }
                change.tag = nil
                var syncFailure = Self.failure(failure.error)
                if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                    guard let copy = received(server, scope: scope) else { continue }
                    syncFailure = .serverRecordChanged(copy)
                }
                if failure.error.code == .zoneNotFound, let zone = Self.zone(for: failure.record.recordID.zoneID, scope: scope) {
                    lock.withLock { _ = createdZones.remove(zone) }
                }
                result.failed.append(FailedSave(change: change, failure: syncFailure))
            }
            // CloudKit reports deletions by record ID alone. The container matches them by ID.
            result.deleted = changes.deletedRecordIDs.compactMap { Self.deletion($0, scope: scope) }
            for (recordID, error) in changes.failedRecordDeletes {
                guard let deletion = Self.deletion(recordID, scope: scope) else { continue }
                result.failedDeletes.append(FailedDelete(deletion: deletion, failure: Self.failure(error)))
            }
            return [.sentRecordChanges(result)]

        case .willFetchChanges:
            return [.willFetchChanges(fetchContext(scope))]
        case .willFetchRecordZoneChanges(let event):
            return Self.zone(for: event.zoneID, scope: scope).map { [.willFetchZoneChanges($0)] } ?? []
        case .didFetchRecordZoneChanges(let event):
            guard let zone = Self.zone(for: event.zoneID, scope: scope) else { return [] }
            return [.didFetchZoneChanges(zone, event.error.map(Self.failure))]
        case .didFetchChanges:
            return [.didFetchChanges(fetchContext(scope))]
        case .willSendChanges(let event):
            return [.willSendChanges(SendContext(
                reason: Self.reason(event.context.reason),
                options: SendOptions(scope: Self.changeScope(event.context.options.scope, scope: scope))
            ))]
        case .didSendChanges(let event):
            return [.didSendChanges(SendContext(
                reason: Self.reason(event.context.reason),
                options: SendOptions(scope: Self.changeScope(event.context.options.scope, scope: scope))
            ))]
        @unknown default:
            return []
        }
    }

    private func fetchContext(_ scope: Zone.Scope) -> FetchContext {
        FetchContext(reason: lock.withLock { manualFetches > 0 } ? .manual : .scheduled, options: FetchOptions(scope: .database(scope)))
    }

    /// A record from the server as a change. Its `CKAsset` files ride along in `assetFiles`, and the
    /// container copies them in before the event ends and CloudKit removes them.
    private func received(_ record: CKRecord, scope: Zone.Scope) -> RecordChangeData? {
        guard let container = lock.withLock({ self.container }),
              let zone = Self.zone(for: record.recordID.zoneID, scope: scope),
              let (change, _) = try? container.change(from: record, zone: zone) else { return nil }
        return change
    }

    /// A saved record as the acknowledgment the container needs: its ID, new tag and save date.
    private static func acknowledged(_ record: CKRecord, scope: Zone.Scope) -> RecordChangeData? {
        guard let zone = zone(for: record.recordID.zoneID, scope: scope), let id = UUID(uuidString: record.recordID.recordName) else {
            return nil
        }
        return RecordChangeData(
            id: id, zone: zone, type: record.recordType, fields: [:],
            tag: RecordContainer.systemFields(of: record), synced: record.modificationDate
        )
    }

    private static func deletion(_ recordID: CKRecord.ID, scope: Zone.Scope) -> RecordDeletion? {
        guard let zone = zone(for: recordID.zoneID, scope: scope), let id = UUID(uuidString: recordID.recordName) else { return nil }
        return RecordDeletion(id: id, zone: zone, type: "")
    }

    // MARK: Translation

    /// Zone names starting with an underscore are SwiftRecords' own, which CloudKit doesn't allow, so they
    /// go under a prefix no app zone can have, since app zone names never hold a dot.
    private static let reservedPrefix = "swiftrecords."

    /// The CloudKit zone a zone syncs to.
    public static func zoneID(_ zone: Zone) -> CKRecordZone.ID {
        let name = zone.name.hasPrefix("_") ? reservedPrefix + zone.name : zone.name
        return CKRecordZone.ID(zoneName: name, ownerName: zone.owner ?? CKCurrentUserDefaultName)
    }

    /// The zone a CloudKit zone in this database stands for, or `nil` for one SwiftRecords didn't make.
    public static func zone(for zoneID: CKRecordZone.ID, scope: Zone.Scope) -> Zone? {
        var name = zoneID.zoneName
        if name.hasPrefix(reservedPrefix) {
            name.removeFirst(reservedPrefix.count)
        } else if name.hasPrefix("_") {
            return nil
        }
        return Zone(stored: name, owner: scope == .shared ? zoneID.ownerName : nil)
    }

    private static func pendingChange(_ change: PendingRecordChange) -> CKSyncEngine.PendingRecordZoneChange {
        switch change {
        case .save(let id, let zone): .saveRecord(RecordContainer.recordID(for: id, in: zoneID(zone)))
        case .delete(let id, let zone): .deleteRecord(RecordContainer.recordID(for: id, in: zoneID(zone)))
        }
    }

    private static func databaseChange(_ change: PendingZoneChange) -> CKSyncEngine.PendingDatabaseChange {
        switch change {
        case .save(let zone): .saveZone(CKRecordZone(zoneID: zoneID(zone)))
        case .delete(let zone): .deleteZone(zoneID(zone))
        }
    }

    private static func reason(_ reason: CKSyncEngine.SyncReason) -> SyncReason {
        switch reason {
        case .manual: .manual
        default: .scheduled
        }
    }

    /// CloudKit's send scope as the container's, for zones in this database alone.
    private static func changeScope(_ scope: CKSyncEngine.SendChangesOptions.Scope, scope database: Zone.Scope) -> ChangeScope {
        switch scope {
        case .all: return .database(database)
        case .zoneIDs(let ids): return .zones(Set(ids.compactMap { zone(for: $0, scope: database) }))
        case .allExcluding(let ids): return .excludingZones(Set(ids.compactMap { zone(for: $0, scope: database) }))
        case .recordIDs(let ids): return .records(Set(ids.compactMap { UUID(uuidString: $0.recordName) }))
        @unknown default: return .database(database)
        }
    }

    /// CloudKit's fetch scope as the container's, for zones in this database alone.
    private static func changeScope(_ scope: CKSyncEngine.FetchChangesOptions.Scope, scope database: Zone.Scope) -> ChangeScope {
        switch scope {
        case .all: return .database(database)
        case .zoneIDs(let ids): return .zones(Set(ids.compactMap { zone(for: $0, scope: database) }))
        case .allExcluding(let ids): return .excludingZones(Set(ids.compactMap { zone(for: $0, scope: database) }))
        @unknown default: return .database(database)
        }
    }

    /// The container's send scope as one engine's, or `nil` when it covers nothing in that database.
    private static func sendOptions(_ options: SendOptions, scope: Zone.Scope) -> CKSyncEngine.SendChangesOptions? {
        switch options.scope {
        case .all:
            return CKSyncEngine.SendChangesOptions(scope: .all)
        case .zones(let zones):
            let ids = zones.filter { $0.scope == scope }.map(zoneID)
            return ids.isEmpty ? nil : CKSyncEngine.SendChangesOptions(scope: .zoneIDs(.init(ids)))
        case .excludingZones(let zones):
            return CKSyncEngine.SendChangesOptions(scope: .allExcluding(.init(zones.filter { $0.scope == scope }.map(zoneID))))
        case .records:
            // Record IDs need their zones, which a set of UUIDs doesn't name, so the whole database sends.
            return CKSyncEngine.SendChangesOptions(scope: .all)
        case .database(let database):
            return database == scope ? CKSyncEngine.SendChangesOptions(scope: .all) : nil
        }
    }

    /// The container's fetch scope as one engine's, or `nil` when it covers nothing in that database.
    private static func fetchOptions(_ scope: ChangeScope, scope database: Zone.Scope) -> CKSyncEngine.FetchChangesOptions? {
        switch scope {
        case .all, .records:
            return CKSyncEngine.FetchChangesOptions(scope: .all)
        case .zones(let zones):
            let ids = zones.filter { $0.scope == database }.map(zoneID)
            return ids.isEmpty ? nil : CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(.init(ids)))
        case .excludingZones(let zones):
            return CKSyncEngine.FetchChangesOptions(scope: .allExcluding(.init(zones.filter { $0.scope == database }.map(zoneID))))
        case .database(let scope):
            return scope == database ? CKSyncEngine.FetchChangesOptions(scope: .all) : nil
        }
    }

    /// A CloudKit error as the failure the container acts on.
    public static func failure(_ error: any Error) -> SyncFailure {
        guard let error = error as? CKError else { return .other("\(error)") }
        switch error.code {
        case .serverRecordChanged: return .other("The server's copy changed")
        case .unknownItem: return .unknownItem
        case .zoneNotFound, .userDeletedZone: return .zoneNotFound
        case .quotaExceeded: return .quotaExceeded
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .notAuthenticated,
             .accountTemporarilyUnavailable:
            return .networkUnavailable
        case .limitExceeded, .assetFileNotFound: return .limitExceeded
        case .permissionFailure: return .permissionFailure
        default: return .other(error.localizedDescription)
        }
    }
}

#endif
