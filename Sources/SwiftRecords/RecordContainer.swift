import Foundation

/// A zone's database file, its asset files and the schema of the records stored in it, in the role
/// SwiftData gives `ModelContainer`.
///
/// You read and write records through a context: `mainContext` on the main actor, or the context that
/// `performBackgroundTask(_:)` hands you for work off the main actor. Containers opened on the same file
/// share one connection, so each sees the other's changes and their contexts refresh together.
public final class RecordContainer: @unchecked Sendable {
    let store: RecordStore
    /// Created on first use by `mainContext`, on the main actor.
    private nonisolated(unsafe) var mainContextStorage: RecordsContext?

    /// The zone this container was opened with, or `nil` when opened by URL.
    public let zone: Zone?

    /// The database file, or `nil` for an in-memory container.
    public var url: URL? { store.url }

    /// Where asset files are stored: beside the database file and named after it, such as
    /// `default.assets`. An in-memory container uses a temporary folder that is removed with it.
    public var assetsDirectory: URL { store.assetsDirectory }

    /// Keeps the zone in step with a server. `nil` for a container that only stores locally. Set once, in `init`.
    private(set) nonisolated(unsafe) var sync: SyncCoordinator?

    /// Where syncing stands, for the main context's `status`.
    @MainActor private(set) var syncPhase: SyncCoordinator.Phase = .idle {
        didSet { mainContextStorage?.syncPhaseChanged() }
    }

    /// How a server's copy and an unsent local edit of the same record are merged.
    public let mergePolicy: MergePolicy
    /// What happens to this device's records when the sync account signs out.
    public let onSignOut: AccountPolicy
    /// What happens to this device's records when a different sync account signs in.
    public let onAccountSwitch: AccountPolicy
    /// What happens to this device's records when the server's copy of the zone is deleted.
    public let onServerReset: AccountPolicy

    /// Opens or creates the zone's file. With no arguments this is `default.sqlite` in
    /// `Zone.defaultDirectory`. Pass `directory` to keep zone files somewhere else, such as an App Group
    /// container from `Zone.directory(appGroup:)`, or a temporary folder in tests.
    public convenience init(zone: Zone = .default, directory: URL? = nil) throws {
        try self.init(for: [], zone: zone, directory: directory)
    }

    /// Opens or creates the zone's file for these record types, and keeps it in sync through
    /// `syncProvider` if you pass one. Types reached through relationships are registered too.
    ///
    /// Registering creates the types' tables and applies renames and indexes now, rather than the first
    /// time code uses each type. A provider needs it, because a server's records can arrive before any code
    /// has touched their type. The provider and policies stay fixed for the container's life.
    public convenience init(
        for types: [any Record.Type],
        zone: Zone = .default,
        directory: URL? = nil,
        syncProvider: (any SyncProvider)? = nil,
        mergePolicy: MergePolicy = .default,
        onSignOut: AccountPolicy = .keepLocalData,
        onAccountSwitch: AccountPolicy = .deleteLocalData,
        onServerReset: AccountPolicy = .keepLocalData
    ) throws {
        let directory = directory ?? Zone.defaultDirectory
        let url = try zone.url(in: directory)
        if url != nil {
            try Zone.prepare(directory)
        }
        try self.init(
            zone: zone, store: RecordStore.open(url: url), types: types, syncProvider: syncProvider,
            policies: .init(merge: mergePolicy, onSignOut: onSignOut, onAccountSwitch: onAccountSwitch, onServerReset: onServerReset)
        )
        Self.register(self)
    }

    /// Opens or creates a database file at an exact location.
    public convenience init(url: URL) throws {
        try self.init(zone: nil, store: RecordStore.open(url: url))
        Self.register(self)
    }

    private init(
        zone: Zone?, store: RecordStore, types: [any Record.Type] = [], syncProvider: (any SyncProvider)? = nil,
        policies: SyncCoordinator.Policies = .init(merge: .default, onSignOut: .keepLocalData, onAccountSwitch: .deleteLocalData, onServerReset: .keepLocalData)
    ) throws {
        self.zone = zone
        self.store = store
        mergePolicy = policies.merge
        onSignOut = policies.onSignOut
        onAccountSwitch = policies.onAccountSwitch
        onServerReset = policies.onServerReset
        try store.register(types, syncSafe: syncProvider != nil)
        guard let syncProvider else { return }
        store.syncEnabled = true
        let sync = SyncCoordinator(provider: syncProvider, store: store, policies: policies) { [weak self] phase in
            Task { @MainActor in self?.syncPhase = phase }
        }
        self.sync = sync
        Task { await sync.open() }
    }

    // MARK: Contexts

    /// The container's main-actor context, which views and app code use to read and write records. The
    /// container keeps it while the container is open, so every caller shares its pending changes.
    @MainActor
    public var mainContext: RecordsContext {
        if let context = mainContextStorage {
            return context
        }
        let context = RecordsContext(container: self)
        mainContextStorage = context
        return context
    }

    /// Runs `body` off the main actor with a context of its own, for work such as an import. Each save
    /// or delete commits right away unless it is inside the context's `transaction(_:)`, and the main
    /// context refreshes after each commit.
    ///
    /// The container serializes access to its file, so the main context waits while a transaction runs.
    /// Keep transactions to a few hundred records, and split a large import into several.
    public func performBackgroundTask<T: Sendable>(
        _ body: @escaping @Sendable (BackgroundContext) throws -> T
    ) async throws -> T {
        try await Task.detached { try body(BackgroundContext(container: self)) }.value
    }

    /// Removes every record and asset file in the zone, along with the change log and sync state, and
    /// discards the main context's pending changes. Use it for signing out or resetting app data. Nothing
    /// is sent to a sync server: the next sync starts over.
    @MainActor
    public func deleteAllData() throws {
        mainContextStorage?.rollback()
        mainContextStorage?.waitForSaves()
        try store.deleteAllData()
    }

    // MARK: Shared containers

    private struct Registration {
        weak var container: RecordContainer?
        /// Set for containers that `shared(_:)` opened, which nothing else keeps alive.
        var retained: RecordContainer?
    }

    private nonisolated(unsafe) static var registry: [String: Registration] = [:]
    private static let registryLock = NSLock()

    /// The container for a zone's file in `Zone.defaultDirectory`: the most recently opened one that is
    /// still alive, or a new one that stays open for the rest of the process. `@Records` uses it for a
    /// zone that isn't in the environment.
    public static func shared(_ zone: Zone = .default) throws -> RecordContainer {
        let key = key(for: try zone.url(in: Zone.defaultDirectory))
        registryLock.lock()
        defer { registryLock.unlock() }
        if let container = registry[key]?.container {
            return container
        }
        let url = try zone.url(in: Zone.defaultDirectory)
        if url != nil {
            try Zone.prepare(Zone.defaultDirectory)
        }
        let container = try RecordContainer(zone: zone, store: RecordStore.open(url: url))
        registry[key] = Registration(container: container, retained: container)
        return container
    }

    private static func key(for url: URL?) -> String {
        url.map(RecordStore.fileKey) ?? "in-memory"
    }

    /// Makes a newly opened container the one `shared(_:)` returns for its file.
    private static func register(_ container: RecordContainer) {
        registryLock.lock()
        defer { registryLock.unlock() }
        registry[key(for: container.url)] = Registration(container: container)
    }
}

// MARK: - Package interface

// Contexts, tests and the sync layer reach the store through these.
extension RecordContainer {
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
