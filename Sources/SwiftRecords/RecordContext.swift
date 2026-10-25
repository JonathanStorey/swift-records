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
/// Inserts, updates and deletes are collected and committed together in one transaction when you call
/// `save()` or `transaction(_:)`, and when the app stops being active, so nothing entered is lost. Until
/// then every view on the context shows them. Only the latest pending change to each record is kept, so
/// rapid edits such as typing cost one write. Views using `@Records`
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

    /// The zone that saves, deletes and fetches use: the container's `initialZone` until you set it. Setting it switches every
    /// `@Records` view that doesn't name a zone of its own, and they fetch again from the new zone. Changes
    /// already pending stay with the zone they were made in. A zone's file opens the first time it's used.
    public var zone: Zone {
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

    /// The error from the most recent save the context made on its own, when the app stopped being active,
    /// if it failed. Its changes stay pending for the next `save()`.
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
        /// The latest save, send or fetch failed. A stored record that no longer decodes, which fetches
        /// skip, shows as `.failed(.incompatibleRecord(type:id:))` until it decodes again or is deleted.
        case failed(RecordsError)
    }

    /// Where this context's changes stand. It works the same with or without a sync provider: a local
    /// container moves between `saving`, `saved` and `failed`.
    public private(set) var status: Status = .saved

    /// How far asset files have got moving to and from the server, from 0 to 1 by file count across the
    /// zones this context uses, or `nil` when none are moving. Records sync first and their files follow,
    /// so a received record's asset reads `nil` until its file lands.
    public private(set) var assetProgress: Double?

    /// How many saved records have changes the sync server hasn't confirmed, across the zones this
    /// context uses. It stays at 0 without a sync provider, and grows while the device is offline or
    /// signed out.
    public private(set) var unsyncedChanges = 0

    /// The error from the latest save, cleared by the next one that succeeds.
    @ObservationIgnored private var saveFailure: RecordsError?
    /// A stored record that no longer decodes, which fetches skip, until it decodes again or is deleted.
    @ObservationIgnored private var undecodable: RecordsError?

    private struct Change: Sendable {
        let zone: Zone
        /// The table of the records the change touches, so views can lay it over their results.
        var table: String? = nil
        let sequence: Int
        let source: ObjectIdentifier?
        /// What the change leaves a single record as, so `hasChanges(in:)` can see it before it commits.
        var latest: Latest? = nil
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
        let bases: [Zone: Int]
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
    @ObservationIgnored private var lifecycle: LifecycleObserver?
    /// The single source of every change in the most recent save, when there was one and the save changed
    /// nothing structural. `@Records` uses it to skip fetching again after its own edits.
    @ObservationIgnored private(set) var lastSaveSource: ObjectIdentifier?
    /// Each zone's commit count as of the last change this context has accounted for.
    @ObservationIgnored private var knownCommits: [Zone: Int] = [:]
    /// The zones this context has used, and its commit observer on each.
    @ObservationIgnored private nonisolated(unsafe) var observed: [Zone: (storage: ZoneStorage, token: UUID)] = [:]
    @ObservationIgnored private var changeHandlers: [ObjectIdentifier: ChangeHandler] = [:]
    /// Runs every commit and async read in order, off the main actor, so a save never overtakes an earlier one.
    @ObservationIgnored private let writer = DispatchQueue(label: "SwiftRecords.RecordContext")
    /// Async saves committing now. Their commits are accounted for when they finish.
    @ObservationIgnored private var savesInFlight = 0 {
        didSet { updateStatus() }
    }

    init(container: RecordContainer) {
        self.container = container
        zone = container.initialZone
        lifecycle = LifecycleObserver(resignActive: { [weak self] in
            self?.saveBeforeLeaving()
        }, becomeActive: { [weak self] in
            guard let self else { return }
            if observed.values.allSatisfy({ $0.storage.sync == nil }) {
                refresh()
            } else {
                Task { try? await self.refresh() }
            }
        })
        observe(container.initialStorage)
        updateStatus()
    }

    deinit {
        for (storage, token) in observed.values {
            storage.removeCommitObserver(token)
        }
    }

    /// The zone's storage, which this context then watches for commits it didn't make.
    func storage(for zone: Zone) throws -> ZoneStorage {
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
        updateUnsyncedChanges()
    }

    private func updateUnsyncedChanges() {
        let count = observed.values.reduce(0) { total, entry in
            guard entry.storage.sync != nil else { return total }
            return total + ((try? entry.storage.store.pendingChangeCount()) ?? 0)
        }
        if count != unsyncedChanges {
            unsyncedChanges = count
        }
    }

    /// Shows a stored record that fetches skip because it no longer decodes, or clears it.
    func undecodableChanged(_ error: RecordsError?) {
        undecodable = error
        updateStatus()
    }

    func assetTransferChanged() {
        let transfers = observed.values.compactMap(\.storage.assetTransfer)
        let total = transfers.reduce(0) { $0 + $1.total }
        let new = total == 0 ? nil : Double(transfers.reduce(0) { $0 + $1.done }) / Double(total)
        if new != assetProgress {
            assetProgress = new
        }
    }

    /// Refreshes views once a downloaded asset file is in place, so its record's asset reads the file.
    func assetDidLand(in zone: Zone) {
        guard observed[zone] != nil else { return }
        lastSaveSource = nil
        didChange()
    }

    private func updateStatus() {
        let new: Status = if savesInFlight > 0 {
            .saving
        } else if let saveFailure {
            .failed(saveFailure)
        } else if let undecodable {
            .failed(undecodable)
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
    private func zoneDidCommit(_ zone: Zone) {
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
        updateUnsyncedChanges()
        notifyHandlers()
    }

    private func notifyHandlers() {
        changeHandlers = changeHandlers.filter { $0.value.owner != nil }
        for handler in changeHandlers.values {
            handler.run()
        }
    }

    public var hasChanges: Bool { !pending.isEmpty }

    /// The number of changes waiting for `save()`. Repeated edits to one record count once.
    public var unsavedChanges: Int { pending.count }

    // MARK: Changes

    /// Adds the record, or replaces the one with the same ID, when the context saves. Views show it at
    /// once, and `rollback()` takes it back until it's saved.
    public func insert<R: Record>(_ record: R) {
        insert(record, in: zone)
    }

    func insert<R: Record>(_ record: R, in zone: Zone, source: ObjectIdentifier? = nil) {
        enqueue(key: Self.key(record, in: zone), zone: zone, table: R.table, source: source, latest: .saved(record)) { try $0.save(record) }
    }

    public func delete<R: Record>(_ record: R) {
        delete(record, in: zone)
    }

    func delete<R: Record>(_ record: R, in zone: Zone, source: ObjectIdentifier? = nil) {
        enqueue(key: Self.key(record, in: zone), zone: zone, table: R.table, source: source, latest: .deleted) { try $0.delete(record) }
    }

    /// Deletes every record of the type that matches the predicate when the context saves, applying each
    /// one's delete rules: `context.delete(record: Recipe.self, where: #Predicate { $0.servings == 0 })`.
    /// Without a predicate it deletes every record of the type.
    public func delete<R: Record>(record type: R.Type, where predicate: Predicate<R>? = nil) {
        let deletes: @Sendable (Any) -> Bool = { record in
            guard let record = record as? R else { return false }
            return (try? predicate?.evaluate(record)) ?? true
        }
        enqueue(
            key: "\(zone.name)|delete|\(R.table)|\(sequence + 1)", zone: zone, table: R.table, source: nil, deletes: deletes
        ) { try $0.delete(type, where: predicate) }
    }

    /// Runs `body`, then saves everything pending in one commit. If `body` throws, the changes it made
    /// are rolled back and earlier unsaved changes stay pending.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let before = pending
        let result: T
        do {
            result = try body()
        } catch {
            pending = before
            lastSaveSource = nil
            didChange()
            throw error
        }
        try save()
        return result
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
        try finish(batch, result, keepingFailures: { _ in true })
    }

    /// Commits every pending change off the main actor, so the interface keeps running
    /// while it waits for the file. If the save fails, the changes stay pending, as with `save()`.
    ///
    /// With a sync provider, this also sends what the server doesn't have yet. The synchronous `save()` only
    /// commits, for moments that can't wait, and its changes go with the next send.
    public func save() async throws {
        if let batch = takePending() {
            try await commit(batch, keepingFailures: { _ in true })
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
        guard !pending.isEmpty else { return }
        pending = [:]
        lastSaveSource = nil
        didChange()
    }

    /// Drops the pending changes from one source, such as one `@Recordable` view, and refreshes views.
    func rollback(source: ObjectIdentifier) {
        let count = pending.count
        pending = pending.filter { $0.value.source != source }
        guard pending.count != count else { return }
        lastSaveSource = nil
        didChange()
    }

    /// Drops one zone's pending changes, before its data is deleted.
    func rollback(in zone: Zone) {
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
        // Refresh views now rather than on the commit observer's later hop, so they show what arrived
        // by the time a pull-to-refresh ends.
        for storage in storages {
            zoneDidCommit(storage.zone)
        }
    }

    /// Blocks until async saves already started have committed.
    func waitForSaves() {
        writer.sync {}
    }

    private func takePending() -> Batch? {
        guard !pending.isEmpty else { return nil }
        let taken = pending
        pending = [:]
        inFlight.merge(taken) { _, newer in newer }
        let changes = taken.values.sorted { $0.sequence < $1.sequence }
        return Batch(taken: taken, changes: changes)
    }

    private func commit(_ batch: Batch, keepingFailures: @escaping (Error) -> Bool) async throws {
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
        var zones: [Zone] = []
        var byZone: [Zone: [Change]] = [:]
        for change in changes {
            if byZone[change.zone] == nil {
                zones.append(change.zone)
            }
            byZone[change.zone, default: []].append(change)
        }
        var bases: [Zone: Int] = [:]
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

    private func finish(_ batch: Batch, _ result: Result<Commit, Error>, keepingFailures: (Error) -> Bool) throws {
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
            if keepingFailures(error) {
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
    /// Runs `body` after every save already started, off the main actor.
    private func onWriter<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writer.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    // MARK: Fetching

    /// Saves pending changes, then fetches the records the descriptor matches in its order, so results
    /// always include your own edits.
    public func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
        try save()
        return try storage(for: zone).fetch(descriptor)
    }

    /// Saves pending changes, then fetches every record of the type, sorted by ID.
    public func fetch<R: Record>(_ type: R.Type) throws -> [R] {
        try fetch(RecordDescriptor<R>())
    }

    /// Saves pending changes, then counts the records the descriptor matches, in SQL when the predicate
    /// translates.
    public func fetchCount<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> Int {
        try save()
        return try storage(for: zone).fetchCount(descriptor)
    }

    /// Saves pending changes, then returns the IDs of the records the descriptor matches in its order,
    /// without loading the records when the predicate and sort translate to SQL.
    public func fetchIdentifiers<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [UUID] {
        try save()
        return try storage(for: zone).fetchIdentifiers(descriptor)
    }

    /// The record with this ID as this context holds it, with any unsaved change, or `nil` if there's
    /// none. It doesn't save, so a view can call it while it updates. The type can come from the
    /// result: `let recipe: Recipe? = try context.record(for: id)`.
    public func record<R: Record>(_ type: R.Type = R.self, for id: R.ID) throws -> R? {
        switch try current(type, id: id, in: zone) {
        case .saved(let record)?: record as? R
        case .deleted?, nil: nil
        }
    }

    /// The record as this context holds it: its unsaved change if it has one, including one a save is
    /// committing now, otherwise the stored copy.
    func current<R: Record>(_ type: R.Type, id: R.ID, in zone: Zone) throws -> Latest? {
        let key = Self.key(type, id: id, in: zone)
        if let latest = (pending[key] ?? inFlight[key])?.latest {
            return latest
        }
        return try storage(for: zone).fetch(type, id: id).map { .saved($0) }
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
    /// Whether changes from `source`, such as one `@Records` view, are waiting to save or saving now.
    func hasPendingChanges(from source: ObjectIdentifier) -> Bool {
        pending.values.contains { $0.source == source } || inFlight.values.contains { $0.source == source }
    }

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
    /// show them before they commit. A saved record takes its place in `order`, and leaves if `includes`
    /// rejects it. A delete by predicate removes the records it matches.
    func overlay<R: Record>(_ stored: [R], in zone: Zone, order: RecordOrder<R> = RecordOrder([]), includes: (R) -> Bool) -> [R] {
        let changes = unsaved.filter { $0.change.zone == zone && $0.change.table == R.table }
        guard !changes.isEmpty else { return stored }
        var records = stored
        for (key, change) in changes {
            switch change.latest {
            case .saved(let any)?:
                guard let record = any as? R else { continue }
                // An edit can change where the record sorts, so it leaves its old place either way.
                if let position = records.firstIndex(where: { $0.id == record.id }) {
                    records.remove(at: position)
                }
                if includes(record) {
                    records.insert(record, at: records.firstIndex { order.areInOrder(record, $0) } ?? records.endIndex)
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
        return records
    }

    // MARK: Arrays

    /// Applies an edited array of records: new IDs are inserted, missing IDs are deleted, and the ones
    /// that changed are updated. The array's order isn't stored, so it returns the records in `order`, as
    /// a fetch lists them. This is what the `@Records` binding calls when SwiftUI writes to it.
    /// Without a zone it applies to the context's current one.
    @discardableResult
    func apply<R: Record>(
        _ records: [R], replacing previous: [R], in zone: Zone? = nil, source: ObjectIdentifier? = nil, order: RecordOrder<R> = RecordOrder([])
    ) -> [R] {
        let zone = zone ?? self.zone
        let kept = Set(records.map(\.id))
        for record in previous where !kept.contains(record.id) {
            enqueue(key: Self.key(record, in: zone), zone: zone, table: R.table, source: source, latest: .deleted) { try $0.delete(record) }
        }
        // Only records the edit changed are saved, so typing in one row doesn't rewrite the whole list.
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records where !(before[record.id].map { StructuralEquality.equal($0, record) } ?? false) {
            enqueue(key: Self.key(record, in: zone), zone: zone, table: R.table, source: source, latest: .saved(record)) { try $0.save(record) }
        }
        return order.sorted(records)
    }

    private static func key<R: Record>(_ record: R, in zone: Zone) -> String {
        key(R.self, id: record.id, in: zone)
    }

    private static func key<R: Record>(_ type: R.Type, id: R.ID, in zone: Zone) -> String {
        "\(zone.name)|record|\(R.table)|\(id)"
    }

    private func enqueue(
        key: String, zone: Zone, table: String? = nil, source: ObjectIdentifier?, latest: Latest? = nil,
        deletes: (@Sendable (Any) -> Bool)? = nil,
        _ run: @escaping @Sendable (ZoneStorage) throws -> Void
    ) {
        // Watch the zone from now on, so commits elsewhere refresh views.
        _ = try? storage(for: zone)
        sequence += 1
        pending[key] = Change(
            zone: zone, table: table, sequence: sequence, source: source, latest: latest, deletes: deletes, run: run
        )
        // Views show unsaved changes at once.
        notifyHandlers()
    }

    /// Whether a save that failed this way may succeed later without anything changing.
    static func isTransient(_ error: Error) -> Bool {
        guard case .database(let code, _)? = error as? RecordsError else { return false }
        // SQLITE_BUSY, LOCKED, READONLY, IOERR, FULL and CANTOPEN, including their extended codes.
        return [5, 6, 8, 10, 13, 14].contains(code & 0xFF)
    }

    /// Saves everything pending when the app stops being active, such as when the user switches apps, so
    /// nothing entered is lost. It can't wait for an async save. A failure keeps the changes pending for
    /// the next `save()` and sets `lastSaveError`.
    func saveBeforeLeaving() {
        guard let batch = takePending() else { return }
        let container = container
        let result = writer.sync { Result { try Self.commit(batch.changes, in: container) } }
        do {
            try finish(batch, result, keepingFailures: { _ in true })
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }
}

/// Saves pending changes when the app stops being active, so nothing entered is lost.
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
