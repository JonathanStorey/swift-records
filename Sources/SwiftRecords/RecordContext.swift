import Foundation
import Observation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A zone's main-actor context, in the role SwiftData gives `ModelContext`. Get it from
/// `RecordContainer.mainContext`, which every view and caller shares. Its `zone` picks which of the
/// container's zones it reads and writes.
///
/// Inserts, updates and deletes are collected and committed together in one transaction, either when
/// you call `save()` or automatically once edits pause for `autosaveDelay`. Only the latest pending
/// change to each record is kept, so rapid edits such as typing cost one write. Views using `@Records`
/// refresh after each save, and after changes written to the zone some other way, such as by a
/// background import, a sync engine or an app extension.
///
/// Saving and fetching have `async` versions, which do the database work off the main actor. Use them in
/// async code so the interface keeps running while a background import holds the file.
@MainActor
@Observable
public final class RecordContext {
    /// The container this context belongs to.
    public let container: RecordContainer

    /// The zone that saves, deletes and fetches use: `nil`, the default zone, until you set it. Setting it switches every
    /// `@Records` view that doesn't name a zone of its own, and they fetch again from the new zone. Changes
    /// already pending stay with the zone they were made in. A zone's file opens the first time it's used.
    public var zone: String? = nil {
        didSet {
            guard zone != oldValue else { return }
            _ = try? storage(for: zone)
            lastSaveSource = nil
            updateStatus()
            didChange()
        }
    }

    /// Incremented after every save, after a rollback, and after the zone commits changes this
    /// context didn't make. `@Records` compares it with its cache to know when to fetch again, and learns
    /// of each change through `onChange(for:_:)`.
    @ObservationIgnored private(set) var changeCount = 0

    /// When true (the default), pending changes are saved automatically after `autosaveDelay`.
    public var autosaveEnabled = true

    /// How long edits must pause before an autosave. Each new change restarts the wait. The default is
    /// half a second; `.zero` saves on the next turn of the main actor. Pending changes are also saved
    /// by `save()`, by every fetch, and when the app moves to the background.
    public var autosaveDelay: Duration = .milliseconds(500)

    /// The error from the most recent autosave, if it failed. A failed autosave discards its changes.
    public private(set) var lastSaveError: Error?

    /// Where this context's changes stand, locally and, with a sync provider, on the server.
    public enum Status: Sendable, Hashable {
        /// Everything is saved, and with a provider, sent.
        case saved
        /// A save is committing.
        case saving
        /// Changes are being sent or fetched.
        case syncing
        /// The server can't be reached. Changes are saved here and sent once it can.
        case offline
        /// No sync account is signed in. Changes are saved here.
        case signedOut
        /// The latest save, send or fetch failed.
        case failed(RecordsError)
    }

    /// Where this context's changes stand. It works the same with or without a sync provider: a local
    /// container moves between `saving`, `saved` and `failed`.
    public private(set) var status: Status = .saved

    /// The error from the latest save, cleared by the next one that succeeds.
    @ObservationIgnored private var saveFailure: RecordsError?

    private struct Change: Sendable {
        let zone: String?
        /// The table of the record or order the change touches, so views can lay it over their results.
        var table: String? = nil
        let sequence: Int
        let source: ObjectIdentifier?
        /// Stored orders run after every record change, so records inserted in the same save take their places.
        var isOrder = false
        /// What the change leaves a single record as, so `hasChanges(in:)` can see it before it commits.
        var latest: Latest? = nil
        /// The IDs a `@Records` binding stored in this order.
        var orderIDs: [UUID]? = nil
        /// Which records of the table a delete by predicate removes.
        var deletes: (@Sendable (Any) -> Bool)? = nil
        let run: @Sendable (ZoneStorage) throws -> Void
    }

    enum Latest: Sendable {
        case saved(any Record)
        case deleted
    }

    /// The changes one save commits, and what it took from `pending`.
    private struct Batch: Sendable {
        let taken: [String: Change]
        let changes: [Change]
    }

    /// What a committed batch reports back to the main actor.
    private struct Commit: Sendable {
        /// Each zone's commit count just before this batch committed to it.
        let bases: [String?: Int]
        let changedStructure: Bool
    }

    private struct ChangeHandler {
        weak var owner: AnyObject?
        let run: @MainActor () -> Void
    }

    /// Pending changes keyed by what they change, such as one record, so a newer change replaces an older one.
    @ObservationIgnored private var pending: [String: Change] = [:]
    /// Numbers each change, so `@Records` can tell which pending changes it has already shown.
    @ObservationIgnored private(set) var sequence = 0
    /// Changes an async save took from `pending` and is committing now. Views keep showing them until it finishes.
    @ObservationIgnored private var inFlight: [String: Change] = [:]
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycle: LifecycleObserver?
    /// The single source of every change in the most recent save, when there was one and the save changed
    /// nothing structural. `@Records` uses it to skip fetching again after its own edits.
    @ObservationIgnored private(set) var lastSaveSource: ObjectIdentifier?
    /// Each zone's commit count as of the last change this context has accounted for.
    @ObservationIgnored private var knownCommits: [String?: Int] = [:]
    /// The zones this context has used, and its commit observer on each.
    @ObservationIgnored private nonisolated(unsafe) var observed: [String?: (storage: ZoneStorage, token: UUID)] = [:]
    @ObservationIgnored private var changeHandlers: [ObjectIdentifier: ChangeHandler] = [:]
    /// Runs every commit and async read in order, off the main actor, so a save never overtakes an earlier one.
    @ObservationIgnored private let writer = DispatchQueue(label: "SwiftRecords.RecordContext")
    /// Async saves committing now. Their commits are accounted for when they finish.
    @ObservationIgnored private var savesInFlight = 0 {
        didSet { updateStatus() }
    }

    init(container: RecordContainer) {
        self.container = container
        lifecycle = LifecycleObserver(resignActive: { [weak self] in
            self?.autosave()
        }, becomeActive: { [weak self] in
            guard let self else { return }
            if observed.values.allSatisfy({ $0.storage.sync == nil }) {
                refresh()
            } else {
                Task { try? await self.refresh() }
            }
        })
        observe(container.defaultStorage)
        updateStatus()
    }

    deinit {
        for (storage, token) in observed.values {
            storage.removeCommitObserver(token)
        }
    }

    /// The zone's storage, which this context then watches for commits it didn't make.
    func storage(for zone: String?) throws -> ZoneStorage {
        if let storage = observed[zone]?.storage {
            return storage
        }
        let storage = try container.storage(for: zone)
        observe(storage)
        return storage
    }

    private func observe(_ storage: ZoneStorage) {
        let zone = storage.zone
        knownCommits[zone] = storage.commitCount
        storage.context = self
        let token = storage.observeCommits { [weak self] in
            Task { @MainActor in self?.zoneDidCommit(zone) }
        }
        observed[zone] = (storage, token)
    }

    func syncPhaseChanged() {
        updateStatus()
    }

    private func updateStatus() {
        let new: Status = if savesInFlight > 0 {
            .saving
        } else if let saveFailure {
            .failed(saveFailure)
        } else {
            switch observed[zone]?.storage.syncPhase ?? .idle {
            case .idle: .saved
            case .syncing: .syncing
            case .offline: .offline
            case .signedOut: .signedOut
            case .failed(let error): .failed(error)
            }
        }
        if new != status {
            status = new
        }
    }

    /// Refreshes views after commits this context didn't make. Its own saves are already counted.
    private func zoneDidCommit(_ zone: String?) {
        guard savesInFlight == 0, let storage = observed[zone]?.storage else { return }
        let commits = storage.commitCount
        guard commits != knownCommits[zone] else { return }
        knownCommits[zone] = commits
        lastSaveSource = nil
        didChange()
    }

    /// Calls `run` after each change that views may need to show, for as long as `owner` is alive.
    /// `@Records` uses it to refresh with its animation.
    func onChange(for owner: AnyObject, _ run: @escaping @MainActor () -> Void) {
        changeHandlers[ObjectIdentifier(owner)] = ChangeHandler(owner: owner, run: run)
    }

    private func didChange() {
        changeCount += 1
        notifyHandlers()
    }

    private func notifyHandlers() {
        changeHandlers = changeHandlers.filter { $0.value.owner != nil }
        for handler in changeHandlers.values {
            handler.run()
        }
    }

    public var hasChanges: Bool { !pending.isEmpty }

    /// The number of unsaved changes. Repeated edits to one record count once, and storing an array's
    /// order counts as one change.
    public var pendingChangeCount: Int { pending.count }

    // MARK: Changes

    /// Adds a new record at the end of its type's stored order. It throws `RecordsError.duplicateID` when a
    /// record with the same ID is already stored or waiting to be saved, so it never overwrites one.
    public func append<R: Record>(_ record: R) throws {
        if case .saved? = try current(R.self, id: record.id, in: zone) {
            throw RecordsError.duplicateID(type: R.table, id: record.id)
        }
        save(record)
    }

    /// Inserts the record, or updates it if one with the same ID exists.
    public func save<R: Record>(_ record: R) {
        save(record, in: zone)
    }

    func save<R: Record>(_ record: R, in zone: String?) {
        enqueue(key: Self.key(record, in: zone), zone: zone, table: R.table, source: nil, latest: .saved(record)) { try $0.save(record) }
    }

    public func delete<R: Record>(_ record: R) {
        delete(record, in: zone)
    }

    func delete<R: Record>(_ record: R, in zone: String?) {
        enqueue(key: Self.key(record, in: zone), zone: zone, table: R.table, source: nil, latest: .deleted) { try $0.delete(record) }
    }

    public func delete<R: Record>(_ type: R.Type, id: R.ID) {
        enqueue(key: Self.key(type, id: id, in: zone), zone: zone, table: R.table, source: nil, latest: .deleted) { try $0.delete(type, id: id) }
    }

    /// Deletes every record that matches the predicate when the context saves, applying each one's
    /// delete rules. Without a predicate it deletes every record of the type.
    public func delete<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) {
        let deletes: @Sendable (Any) -> Bool = { record in
            guard let record = record as? R else { return false }
            return (try? predicate?.evaluate(record)) ?? true
        }
        enqueue(
            key: "\(zone ?? "")|delete|\(R.table)|\(sequence + 1)", zone: zone, table: R.table, source: nil, deletes: deletes
        ) { try $0.delete(type, where: predicate) }
    }

    /// Commits every pending change, in one transaction for each zone they touch. If the save fails, the
    /// changes stay pending so you can fix the cause and save again, or discard them with `rollback()`.
    public func save() throws {
        guard let batch = takePending() else {
            waitForSaves()
            return
        }
        let container = container
        let result = writer.sync { Result { try Self.commit(batch.changes, in: container) } }
        try finish(batch, result, keepingFailures: true)
    }

    /// Commits every pending change off the main actor, so the interface keeps running
    /// while it waits for the file. If the save fails, the changes stay pending, as with `save()`.
    ///
    /// With a sync provider, this also sends what the server doesn't have yet. Autosave does too. The
    /// synchronous `save()` only commits, for moments that can't wait, and its changes go with the next send.
    public func save() async throws {
        if let batch = takePending() {
            try await commit(batch, keepingFailures: true)
        } else {
            try await onWriter {}
        }
        await send()
    }

    /// Sends what each zone's server doesn't have yet.
    private func send() async {
        for (storage, _) in observed.values {
            await storage.sync?.send()
        }
    }

    /// Drops pending changes that have not been saved. Views refresh, so edits made through a `@Records`
    /// binding disappear with them.
    public func rollback() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard !pending.isEmpty else { return }
        pending = [:]
        lastSaveSource = nil
        didChange()
    }

    /// Drops one zone's pending changes, before its data is deleted.
    func rollback(in zone: String?) {
        pending = pending.filter { $0.value.zone != zone }
    }

    /// Picks up changes another process, such as a widget or app extension, wrote to the zone's file, and
    /// refreshes views if there are any. The context also checks when the app becomes active, and every
    /// save and fetch reads the latest data whether or not you call this.
    public func refresh() {
        for (storage, _) in observed.values {
            storage.checkForExternalChanges()
        }
    }

    /// Saves, picks up changes other processes wrote, and with a sync provider, sends what is pending and
    /// fetches the server's changes. It returns once they're stored, so it suits pull-to-refresh. It
    /// throws only what leaves `status` at `failed`: being offline or signed out isn't an error.
    public func refresh() async throws {
        try await save()
        let storages = observed.values.map(\.storage)
        try await onWriter {
            for storage in storages {
                storage.checkForExternalChanges()
            }
        }
        for storage in storages {
            try await storage.sync?.refresh()
        }
    }

    /// Blocks until async saves already started have committed.
    func waitForSaves() {
        writer.sync {}
    }

    private func takePending() -> Batch? {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard !pending.isEmpty else { return nil }
        let taken = pending
        pending = [:]
        inFlight.merge(taken) { _, newer in newer }
        let changes = taken.values.sorted { ($0.isOrder ? 1 : 0, $0.sequence) < ($1.isOrder ? 1 : 0, $1.sequence) }
        return Batch(taken: taken, changes: changes)
    }

    private func commit(_ batch: Batch, keepingFailures: Bool) async throws {
        savesInFlight += 1
        let container = container
        let changes = batch.changes
        let result = await withCheckedContinuation { continuation in
            writer.async {
                continuation.resume(returning: Result { try Self.commit(changes, in: container) })
            }
        }
        savesInFlight -= 1
        try finish(batch, result, keepingFailures: keepingFailures)
    }

    /// Commits each zone's changes in a transaction of its own, zone by zone in the order they were first made.
    private nonisolated static func commit(_ changes: [Change], in container: RecordContainer) throws -> Commit {
        var zones: [String?] = []
        var byZone: [String?: [Change]] = [:]
        for change in changes {
            if byZone[change.zone] == nil {
                zones.append(change.zone)
            }
            byZone[change.zone, default: []].append(change)
        }
        var bases: [String?: Int] = [:]
        var changedStructure = false
        for zone in zones {
            let storage = try container.storage(for: zone)
            let structure = storage.structureVersion
            try storage.transaction {
                bases[zone] = storage.commitCount
                for change in byZone[zone]! {
                    try change.run(storage)
                }
            }
            changedStructure = changedStructure || storage.structureVersion != structure
        }
        return Commit(bases: bases, changedStructure: changedStructure)
    }

    private func finish(_ batch: Batch, _ result: Result<Commit, Error>, keepingFailures: Bool) throws {
        for (key, change) in batch.taken where inFlight[key]?.sequence == change.sequence {
            inFlight[key] = nil
        }
        let commit: Commit
        do {
            commit = try result.get()
            saveFailure = nil
        } catch {
            saveFailure = (error as? RecordsError) ?? .database(code: -1, message: "\(error)")
            updateStatus()
            if keepingFailures {
                pending = batch.taken.merging(pending) { _, newer in newer }
            } else {
                // Views may show edits that were never stored.
                lastSaveSource = nil
                didChange()
            }
            throw error
        }
        updateStatus()
        // Commits from elsewhere since the last refresh, or right after this one, mean views must fetch.
        var outside = false
        for (zone, base) in commit.bases {
            let commits = observed[zone]?.storage.commitCount ?? base + 1
            outside = outside || base != knownCommits[zone] || commits > base + 1
            knownCommits[zone] = commits
        }
        let sources = Set(batch.changes.map(\.source))
        lastSaveSource = !outside && sources.count == 1 && !commit.changedStructure ? sources.first! : nil
        didChange()
    }

    /// Runs `body` with the current zone's storage after every save already started, off the main actor.
    private func read<T: Sendable>(_ body: @escaping @Sendable (ZoneStorage) throws -> T) async throws -> T {
        let storage = try storage(for: zone)
        return try await onWriter { try body(storage) }
    }

    /// Runs `body` after every save already started, off the main actor.
    private func onWriter<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writer.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    // MARK: Fetching

    /// Saves pending changes, then fetches records in their stored order, so results always include your
    /// own edits. Simple predicates on a record's own properties run as SQL. Anything else is evaluated
    /// in memory.
    public func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil) throws -> [R] {
        try save()
        return try storage(for: zone).fetch(type, where: predicate)
    }

    /// Saves pending changes, then fetches one page: at most `limit` records, starting `offset` records
    /// into the results. The slice's indices are the records' positions in the full results, so a page
    /// fetched with an offset of 40 starts at index 40.
    public func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        limit: Int,
        offset: Int = 0
    ) throws -> RecordSlice<R> {
        try save()
        return try storage(for: zone).fetch(type, where: predicate, limit: limit, offset: offset)
    }

    /// Saves pending changes, then counts in SQL when the predicate translates.
    public func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try save()
        return try storage(for: zone).count(type, where: predicate)
    }

    /// The record as this context holds it: its pending change if it has one, otherwise the stored copy.
    /// Unlike a fetch, it doesn't save, so a view can call it while it updates.
    func current<R: Record>(_ type: R.Type, id: R.ID, in zone: String?) throws -> Latest? {
        if let latest = pending[Self.key(type, id: id, in: zone)]?.latest {
            return latest
        }
        return try storage(for: zone).fetch(type, id: id).map { .saved($0) }
    }

    public func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try save()
        return try storage(for: zone).fetch(type, id: id)
    }

    /// Saves pending changes, then fetches records by ID in the order given, skipping any that no longer
    /// exist.
    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try save()
        return try storage(for: zone).fetch(type, ids: ids)
    }

    /// Saves pending changes, then fetches records by ID in their stored order, skipping any that no longer
    /// exist. Use it to load an inverse relationship: `context.fetch(Cookbook.self, ids: recipe.cookbookIDs)`.
    public func fetch<R: Record>(_ type: R.Type, ids: Set<UUID>) throws -> [R] {
        try save()
        return try storage(for: zone).fetch(type, ids: ids)
    }

    // MARK: Fetching off the main actor

    /// Saves pending changes, then fetches records off the main actor. See `fetch(_:where:)`.
    public func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil) async throws -> [R] {
        try await save()
        return try await read { try $0.fetch(type, where: predicate) }
    }

    /// Saves pending changes, then fetches one page off the main actor. See `fetch(_:where:limit:offset:)`.
    public func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        limit: Int,
        offset: Int = 0
    ) async throws -> RecordSlice<R> {
        try await save()
        return try await read { try $0.fetch(type, where: predicate, limit: limit, offset: offset) }
    }

    public func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) async throws -> Int {
        try await save()
        return try await read { try $0.count(type, where: predicate) }
    }

    public func fetch<R: Record>(_ type: R.Type, id: R.ID) async throws -> R? {
        try await save()
        return try await read { try $0.fetch(type, id: id) }
    }

    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) async throws -> [R] {
        try await save()
        return try await read { try $0.fetch(type, ids: ids) }
    }

    public func fetch<R: Record>(_ type: R.Type, ids: Set<UUID>) async throws -> [R] {
        try await save()
        return try await read { try $0.fetch(type, ids: ids) }
    }

    // MARK: Change tracking

    /// Saves pending changes, then returns the token of the latest change. Store it before you start
    /// reading changes.
    package var changeToken: ChangeToken {
        get throws {
            try save()
            return try storage(for: zone).changeToken
        }
    }

    /// Saves pending changes, then returns each record's latest change after `token`, oldest first. Store
    /// the last change's token and pass it next time.
    package func changes(since token: ChangeToken = .initial) throws -> [RecordChange] {
        try save()
        return try storage(for: zone).changes(since: token)
    }

    /// Saves pending changes, then returns a record's version, modification time and tag, or `nil` when
    /// the record doesn't exist.
    public func metadata<R: Record>(_ type: R.Type, id: R.ID) throws -> RecordMetadata? {
        try save()
        return try storage(for: zone).metadata(type, id: id)
    }

    // MARK: Unsaved changes in views

    /// Whether changes made after `sequence` by anything other than `source` aren't saved yet.
    func hasPendingChanges(after sequence: Int, excluding source: ObjectIdentifier) -> Bool {
        unsaved.contains { $0.change.sequence > sequence && $0.change.source != source }
    }

    /// Unsaved changes, including those a save is committing now, newest last.
    private var unsaved: [(key: String, change: Change)] {
        inFlight.merging(pending) { _, newer in newer }
            .map { (key: $0.key, change: $0.value) }
            .sorted { $0.change.sequence < $1.change.sequence }
    }

    /// Records as fetched, with this context's unsaved saves and deletes of the type laid over them, so views
    /// show them before they commit. A saved record replaces its stored copy in place, or joins the end, as a
    /// new record does when it commits, and leaves if `includes` rejects it. A delete by predicate removes
    /// the records it matches. With a `source`, that view's unsaved order applies too.
    func overlay<R: Record>(
        _ stored: [R], in zone: String?, source: ObjectIdentifier? = nil, includes: (R) -> Bool
    ) -> [R] {
        let changes = unsaved.filter { $0.change.zone == zone && $0.change.table == R.table }
        guard !changes.isEmpty else { return stored }
        var records = stored
        for (key, change) in changes {
            switch change.latest {
            case .saved(let any)?:
                guard let record = any as? R else { continue }
                let position = records.firstIndex { $0.id == record.id }
                if !includes(record) {
                    if let position { records.remove(at: position) }
                } else if let position {
                    records[position] = record
                } else {
                    records.append(record)
                }
            case .deleted?:
                // A record change's key ends with the record's ID.
                if let id = key.split(separator: "|").last.flatMap({ UUID(uuidString: String($0)) }) {
                    records.removeAll { $0.id == id }
                }
            case nil:
                if let deletes = change.deletes {
                    records.removeAll { deletes($0) }
                }
            }
        }
        let orderKey = Self.orderKey(R.self, in: zone, source: source)
        if source != nil, let ids = changes.last(where: { $0.key == orderKey })?.change.orderIDs {
            // The view's own order, among the records it holds, in the slots they already take.
            let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let slots = records.indices.filter { rank[records[$0].id] != nil }
            let ordered = slots.map { records[$0] }.sorted { rank[$0.id]! < rank[$1.id]! }
            for (slot, record) in zip(slots, ordered) {
                records[slot] = record
            }
        }
        return records
    }

    /// The record as views should show it: an unsaved save or delete if there is one, otherwise `stored`.
    func overlay<R: Record>(_ stored: R?, id: UUID, in zone: String?) -> R? {
        let key = Self.key(R.self, id: id, in: zone)
        switch (pending[key] ?? inFlight[key])?.latest {
        case .saved(let any)?: return (any as? R) ?? stored
        case .deleted?: return nil
        case nil: return stored
        }
    }

    // MARK: Arrays

    /// Applies an edited array of records: new IDs are inserted, missing IDs are deleted, and the rest
    /// are updated. The array's order becomes the stored order among these records, leaving others in
    /// place. This is what the `@Records` binding calls when SwiftUI writes to it.
    /// Without a zone it applies to the context's current one.
    func apply<R: Record>(_ records: [R], replacing previous: [R], in zone: String?? = nil, source: ObjectIdentifier? = nil) {
        let zone = zone ?? self.zone
        let kept = Set(records.map(\.id))
        for record in previous where !kept.contains(record.id) {
            enqueue(key: Self.key(record, in: zone), zone: zone, table: R.table, source: source, latest: .deleted) { try $0.delete(record) }
        }
        for record in records {
            enqueue(key: Self.key(record, in: zone), zone: zone, table: R.table, source: source, latest: .saved(record)) { try $0.save(record) }
        }
        let ids = records.map(\.id)
        enqueue(key: Self.orderKey(R.self, in: zone, source: source), zone: zone, table: R.table, source: source, isOrder: true, orderIDs: ids) {
            try $0.setOrder(ids, for: R.self)
        }
    }

    private static func key<R: Record>(_ record: R, in zone: String?) -> String {
        key(R.self, id: record.id, in: zone)
    }

    private static func key<R: Record>(_ type: R.Type, id: R.ID, in zone: String?) -> String {
        "\(zone ?? "")|record|\(R.table)|\(id)"
    }

    private static func orderKey<R: Record>(_ type: R.Type, in zone: String?, source: ObjectIdentifier?) -> String {
        "\(zone ?? "")|order|\(R.table)|\(source.map { "\($0)" } ?? "")"
    }

    private func enqueue(
        key: String, zone: String?, table: String? = nil, source: ObjectIdentifier?, isOrder: Bool = false,
        latest: Latest? = nil, orderIDs: [UUID]? = nil, deletes: (@Sendable (Any) -> Bool)? = nil,
        _ run: @escaping @Sendable (ZoneStorage) throws -> Void
    ) {
        // Watch the zone from now on, so commits elsewhere refresh views.
        _ = try? storage(for: zone)
        sequence += 1
        pending[key] = Change(
            zone: zone, table: table, sequence: sequence, source: source, isOrder: isOrder, latest: latest,
            orderIDs: orderIDs, deletes: deletes, run: run
        )
        // Views show unsaved changes at once.
        notifyHandlers()
        guard autosaveEnabled else { return }
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            await self?.autosaveInBackground()
        }
    }

    // Nobody can fix and retry an autosave, and a change that always fails would block every later save,
    // so a failed autosave discards its changes and views show what is stored.

    /// Saves before the app leaves the foreground, which can't wait for an async save.
    private func autosave() {
        guard autosaveEnabled, let batch = takePending() else { return }
        let container = container
        let result = writer.sync { Result { try Self.commit(batch.changes, in: container) } }
        do {
            try finish(batch, result, keepingFailures: false)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }

    private func autosaveInBackground() async {
        guard autosaveEnabled, let batch = takePending() else { return }
        do {
            try await commit(batch, keepingFailures: false)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
        await send()
    }
}

/// Saves pending changes when the app stops being active, so a delayed autosave is never lost.
private final class LifecycleObserver {
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    init(resignActive: @escaping @MainActor @Sendable () -> Void, becomeActive: @escaping @MainActor @Sendable () -> Void) {
        #if canImport(UIKit) && !os(watchOS)
        let leaving = [UIApplication.willResignActiveNotification, UIApplication.willTerminateNotification]
        let returning = [UIApplication.didBecomeActiveNotification]
        #elseif canImport(AppKit)
        let leaving = [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification]
        let returning = [NSApplication.didBecomeActiveNotification]
        #else
        let leaving: [Notification.Name] = []
        let returning: [Notification.Name] = []
        #endif
        let observe = { (names: [Notification.Name], handler: @escaping @MainActor @Sendable () -> Void) in
            names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { handler() }
                }
            }
        }
        tokens = observe(leaving, resignActive) + observe(returning, becomeActive)
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
