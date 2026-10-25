import Foundation

/// A folder of zones, the schema of the records stored in them and how they sync, in the role SwiftData
/// gives `ModelContainer`.
///
/// A `Zone` names a database file in the folder: `"drafts"` is `drafts.sqlite`, and `.default` is
/// `_default.sqlite`. Each zone opens the first time it's used. You read and write records
/// through `mainContext` on the main actor, whose `zone` picks the zone, or through the context that
/// `performBackgroundTask(in:_:)` hands you for work off the main actor. Containers opened on the same
/// folder share each file's connection, so they see each other's changes.
///
/// ```swift
/// let container = try RecordContainer(for: [Recipe.self])   // Application Support/Records
/// let context = container.mainContext
/// context.zone = "drafts"                                     // drafts.sqlite beside _default.sqlite
/// ```
///
/// Records and their relationships live in one zone. A save commits each zone it touches in a transaction
/// of its own.
public final class RecordContainer: @unchecked Sendable {
    /// The folder holding the zone files, or `nil` for an in-memory container.
    public let directory: URL?

    /// The zone the main context starts in, opened with the container.
    public let initialZone: Zone

    private let types: [any Record.Type]
    private let syncProvider: (any SyncProvider)?
    /// The initial zone, opened with the container so `mainContext` can't fail.
    let initialStorage: ZoneStorage
    private var storages: [Zone: ZoneStorage]
    /// Created on first use by `mainContext`, on the main actor.
    private nonisolated(unsafe) var mainContextStorage: RecordContext?
    private let lock = NSLock()

    /// Opens a folder of zones, `Application Support/Records` unless you pass `directory`, such as an App Group
    /// folder from `RecordContainer.directory(appGroup:)`. Previews and tests can pass a temporary folder.
    ///
    /// Registering types creates their tables and applies renames and indexes in each zone as it opens,
    /// rather than the first time code uses each type. Types reached through relationships are registered
    /// too. A sync provider needs it, because a server's records can arrive before any code has touched their
    /// type.
    ///
    /// `syncProvider` keeps each zone in step with its zone on the server, except `.inMemory` and `.localOnly`,
    /// which never sync, and any zone the provider's `syncs(_:)` turns down. The provider decides which zones
    /// are public. The provider stays fixed for the container's life.
    ///
    /// `initialZone` is where the main context starts and what methods that take an optional zone use. It
    /// opens with the container, so an error opening it throws here. Switch zones later with
    /// `RecordContext.zone`.
    public convenience init(
        for types: [any Record.Type] = [],
        directory: URL? = nil,
        initialZone: Zone = .default,
        syncProvider: (any SyncProvider)? = nil
    ) throws {
        try self.init(for: types, directory: directory, inMemory: false, initialZone: initialZone, syncProvider: syncProvider)
    }

    /// With `inMemory`, every zone lives only as long as the container, for tests.
    package init(
        for types: [any Record.Type] = [],
        directory: URL? = nil,
        inMemory: Bool,
        initialZone: Zone = .default,
        syncProvider: (any SyncProvider)? = nil
    ) throws {
        let directory = inMemory ? nil : directory ?? RecordContainer.defaultDirectory
        if let directory {
            try RecordContainer.prepare(directory)
        }
        self.directory = directory
        self.initialZone = initialZone
        self.types = types
        self.syncProvider = syncProvider
        initialStorage = try Self.open(initialZone, directory: directory, types: types, syncProvider: syncProvider)
        storages = [initialZone: initialStorage]
        if directory != nil {
            Self.register(self)
        }
    }

    private static func open(
        _ zone: Zone, directory: URL?, types: [any Record.Type], syncProvider: (any SyncProvider)?
    ) throws -> ZoneStorage {
        let store = try RecordStore.open(url: directory.flatMap { zone.url(in: $0) })
        let provider = zone.canSync && syncProvider?.syncs(zone) == true ? syncProvider : nil
        return try ZoneStorage(
            zone: zone, store: store, types: types, syncProvider: provider, isPublic: provider?.isPublic(zone) ?? false
        )
    }

    /// The zone's storage, opening its file the first time.
    func storage(for zone: Zone) throws -> ZoneStorage {
        lock.lock()
        defer { lock.unlock() }
        if let storage = storages[zone] {
            return storage
        }
        let storage = try Self.open(zone, directory: directory, types: types, syncProvider: syncProvider)
        storages[zone] = storage
        return storage
    }

    /// The zone's database file, the initial zone's by default, or `nil` in memory.
    public func url(for zone: Zone? = nil) -> URL? {
        directory.flatMap { (zone ?? initialZone).url(in: $0) }
    }

    // MARK: Contexts

    /// The container's main-actor context, which views and app code use to read and write records. The
    /// container keeps it while the container is open, so every caller shares its pending changes and zone.
    @MainActor
    public var mainContext: RecordContext {
        if let context = mainContextStorage {
            return context
        }
        let context = RecordContext(container: self)
        mainContextStorage = context
        return context
    }

    /// Runs `body` off the main actor with a context of its own in the zone, the initial zone by default, for
    /// work such as an import.
    /// Each save or delete commits right away unless it is inside the context's `transaction(_:)`, and the
    /// zone's main context refreshes after each commit.
    ///
    /// Each zone serializes access to its file, so the main context waits while a transaction runs. Keep
    /// transactions to a few hundred records, and split a large import into several.
    public func performBackgroundTask<T: Sendable>(
        in zone: Zone? = nil,
        _ body: @escaping @Sendable (BackgroundContext) throws -> T
    ) async throws -> T {
        let storage = try storage(for: zone ?? initialZone)
        return try await Task.detached { try body(BackgroundContext(storage: storage)) }.value
    }

    /// Removes every record and asset file in the zone, the initial zone by default, along with its change log
    /// and sync state, and
    /// discards its main context's pending changes. Use it for signing out or resetting app data. Nothing
    /// is sent to a sync server: the next sync starts over.
    @MainActor
    public func deleteAllData(in zone: Zone? = nil) throws {
        let zone = zone ?? initialZone
        mainContextStorage?.rollback(in: zone)
        mainContextStorage?.waitForSaves()
        try storage(for: zone).deleteAllData()
    }

    // MARK: Shared containers

    private struct Registration {
        weak var container: RecordContainer?
        /// Set for a container that `shared(in:)` opened, which nothing else keeps alive.
        var retained: RecordContainer?
    }

    private nonisolated(unsafe) static var registry: [String: Registration] = [:]
    private static let registryLock = NSLock()

    /// The container `@Records` and `\.recordContext` use when a view's environment has none: the most
    /// recently opened container on the folder that is still alive, or a new one that stays open for the
    /// rest of the process.
    static func shared(in directory: URL = RecordContainer.defaultDirectory) throws -> RecordContainer {
        let key = RecordStore.fileKey(directory)
        registryLock.lock()
        if let container = registry[key]?.container {
            registryLock.unlock()
            return container
        }
        registryLock.unlock()
        let container = try RecordContainer(directory: directory)
        registryLock.lock()
        defer { registryLock.unlock() }
        registry[key]?.retained = container
        return container
    }

    private static func register(_ container: RecordContainer) {
        guard let directory = container.directory else { return }
        registryLock.lock()
        defer { registryLock.unlock() }
        registry[RecordStore.fileKey(directory)] = Registration(container: container)
    }
}

// MARK: - Package interface

// Tests reach the initial zone's store through these.
extension RecordContainer {
    package func transaction<T>(_ body: () throws -> T) throws -> T {
        try initialStorage.transaction(body)
    }

    package func save<R: Record>(_ record: R) throws {
        try initialStorage.save(record)
    }

    package func save<R: Record>(_ records: [R]) throws {
        try initialStorage.save(records)
    }

    package func delete<R: Record>(_ record: R) throws {
        try initialStorage.delete(record)
    }

    package func delete<R: Record>(_ type: R.Type, id: R.ID) throws {
        try initialStorage.delete(type, id: id)
    }

    package func delete<R: Record>(_ type: R.Type, where predicate: Predicate<R>?) throws {
        try initialStorage.delete(type, where: predicate)
    }

    package func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try initialStorage.fetch(type, id: id)
    }

    package func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try initialStorage.fetch(type, ids: ids)
    }

    package func fetch<R: Record>(_ type: R.Type, ids: Set<UUID>) throws -> [R] {
        try initialStorage.fetch(type, ids: ids)
    }

    package func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil) throws -> [R] {
        try initialStorage.fetch(type, where: predicate)
    }

    package func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try initialStorage.count(type, where: predicate)
    }

    package var changeToken: ChangeToken {
        get throws { try initialStorage.changeToken }
    }

    package func changes(since token: ChangeToken = .initial) throws -> [RecordChange] {
        try initialStorage.changes(since: token)
    }

    package func metadata<R: Record>(_ type: R.Type, id: R.ID) throws -> RecordMetadata? {
        try initialStorage.metadata(type, id: id)
    }

    package func setTag<R: Record>(_ tag: Data?, for type: R.Type, id: R.ID) throws {
        try initialStorage.setTag(tag, for: type, id: id)
    }

    package func applyingSyncedChanges<T>(_ body: () throws -> T) throws -> T {
        try initialStorage.applyingSyncedChanges(body)
    }

    package func syncValue(forKey key: String) throws -> Data? {
        try initialStorage.syncValue(forKey: key)
    }

    package func setSyncValue(_ value: Data?, forKey key: String) throws {
        try initialStorage.setSyncValue(value, forKey: key)
    }

    package func fetch<R: Record>(
        _ type: R.Type = R.self, where predicate: Predicate<R>? = nil, limit: Int, offset: Int = 0
    ) throws -> RecordSlice<R> {
        try initialStorage.fetch(type, where: predicate, limit: limit, offset: offset)
    }

    var commitCount: Int { initialStorage.commitCount }
    var structureVersion: Int { initialStorage.structureVersion }
    package var url: URL? { initialStorage.url }
    package var assetsDirectory: URL { initialStorage.assetsDirectory }
}
