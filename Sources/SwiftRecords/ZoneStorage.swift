import Foundation

/// One zone's open database file, its asset files and its sync coordinator. A `RecordContainer` opens one
/// for each zone it uses, and every context of that zone works through it.
package final class ZoneStorage: @unchecked Sendable {
    let store: RecordStore
    /// The container's main context, once it has used this zone. It hears about sync phase changes.
    nonisolated(unsafe) weak var context: RecordContext?

    let zone: Zone

    /// The database file, or `nil` for an in-memory zone.
    var url: URL? { store.url }

    /// Where asset files are stored: beside the database file and named after it, such as
    /// `default.assets`. An in-memory zone uses a temporary folder that is removed with it.
    var assetsDirectory: URL { store.assetsDirectory }

    /// Keeps the zone in step with a server. `nil` for a zone that only stores locally. Set once, in `init`.
    private(set) nonisolated(unsafe) var sync: SyncCoordinator?

    /// Where syncing stands, for the main context's `status`.
    @MainActor private(set) var syncPhase: SyncCoordinator.Phase = .idle {
        didSet { context?.syncPhaseChanged() }
    }

    /// How far the zone's asset files have got moving to and from the server, `nil` when none are.
    @MainActor private(set) var assetTransfer: SyncCoordinator.Transfer? {
        didSet { context?.assetTransferChanged() }
    }

    /// Downloads whenever the provider pushes word that the zone changed.
    private var pushTask: Task<Void, Never>?

    init(
        zone: Zone, store: RecordStore, types: [any Record.Type], syncProvider: (any SyncProvider)?, isPublic: Bool = false,
        policies: SyncCoordinator.Policies
    ) throws {
        self.zone = zone
        self.store = store
        try store.register(types, syncSafe: syncProvider != nil)
        store.undecodableChanged = { [weak self] error in
            Task { @MainActor in self?.context?.undecodableChanged(error) }
        }
        guard let syncProvider else { return }
        store.syncEnabled = true
        let sync = SyncCoordinator(
            provider: syncProvider, zone: zone, isPublic: isPublic, store: store, policies: policies,
            phaseChanged: { [weak self] phase in
                Task { @MainActor in self?.syncPhase = phase }
            },
            transferChanged: { [weak self] transfer, landed in
                // Waiting for the main actor keeps updates in order, and the transfer isn't done until views know.
                await MainActor.run {
                    guard let self else { return }
                    self.assetTransfer = transfer
                    // The record already points at the file, so only views need to know it's here.
                    if landed { self.context?.assetDidLand(in: zone) }
                }
            }
        )
        self.sync = sync
        Task { await sync.open() }
        if let pushes = syncProvider.pushedChanges() {
            pushTask = Task { [weak sync] in
                for await zones in pushes where zones.contains(zone) {
                    await sync?.pushed()
                }
            }
        }
    }

    deinit {
        pushTask?.cancel()
    }

    /// Removes every record and asset file in the zone, along with the change log and sync state.
    func deleteAllData() throws {
        try store.deleteAllData()
    }
}

// MARK: - Package interface

// Contexts, tests and the sync layer reach the store through these.
extension ZoneStorage {
    package func transaction<T>(_ body: () throws -> T) throws -> T {
        try store.transaction(body)
    }

    package func save<R: Record>(_ record: R) throws {
        try store.save(record)
    }

    package func save<R: Record>(_ records: [R]) throws {
        try store.save(records)
    }

    package func setOrder<R: Record>(_ ids: [R.ID], for type: R.Type) throws {
        try store.setOrder(ids, for: type)
    }

    package func delete<R: Record>(_ record: R) throws {
        try store.delete(record)
    }

    package func delete<R: Record>(_ type: R.Type, id: R.ID) throws {
        try store.delete(type, id: id)
    }

    package func delete<R: Record>(_ type: R.Type, where predicate: Predicate<R>?) throws {
        try store.delete(type, where: predicate)
    }

    package func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try store.fetch(type, id: id)
    }

    package func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try store.fetch(type, ids: ids)
    }

    package func fetch<R: Record>(_ type: R.Type, ids: Set<UUID>) throws -> [R] {
        try store.fetch(type, ids: ids)
    }

    package func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil) throws -> [R] {
        try store.fetch(type, where: predicate)
    }

    package func fetch<R: Record>(
        _ type: R.Type = R.self, where predicate: Predicate<R>? = nil, limit: Int, offset: Int = 0
    ) throws -> RecordSlice<R> {
        try store.fetch(type, where: predicate, limit: limit, offset: offset)
    }

    package func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try store.count(type, where: predicate)
    }

    package var changeToken: ChangeToken {
        get throws { try store.changeToken }
    }

    package func changes(since token: ChangeToken = .initial) throws -> [RecordChange] {
        try store.changes(since: token)
    }

    package func metadata<R: Record>(_ type: R.Type, id: R.ID) throws -> RecordMetadata? {
        try store.metadata(type, id: id)
    }

    package func setTag<R: Record>(_ tag: Data?, for type: R.Type, id: R.ID) throws {
        try store.setTag(tag, for: type, id: id)
    }

    package func applyingSyncedChanges<T>(_ body: () throws -> T) throws -> T {
        try store.applyingSyncedChanges(body)
    }

    package func syncValue(forKey key: String) throws -> Data? {
        try store.syncValue(forKey: key)
    }

    package func setSyncValue(_ value: Data?, forKey key: String) throws {
        try store.setSyncValue(value, forKey: key)
    }

    func checkForExternalChanges() {
        store.checkForExternalChanges()
    }

    var commitCount: Int { store.commitCount }
    var structureVersion: Int { store.structureVersion }

    func observeCommits(_ handler: @escaping @Sendable () -> Void) -> UUID {
        store.observeCommits(handler)
    }

    func removeCommitObserver(_ token: UUID) {
        store.removeCommitObserver(token)
    }
}
