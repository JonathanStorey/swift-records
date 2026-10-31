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

    /// The records in the context's zone whose saved changes the sync server hasn't confirmed. It
    /// is empty without a sync provider, and unsaved edits aren't in it until they save.
    ///
    /// ```swift
    /// if context.unsynced.contains(note.id) { Image(systemName: "icloud.slash") }
    /// ```
    public var unsynced: Set<UUID> { unsynced(in: zone) }

    /// Each zone's changes the server hasn't confirmed, as of the last update. It changes when which
    /// records they are does, which tells views reading `unsynced` to read again.
    private var unsyncedSummaries: [Zone: RecordStore.PendingSummary] = [:]
    /// Each zone's unsynced records, read the first time they're asked for after a change, so a sync of
    /// many records doesn't read them all after every batch.
    @ObservationIgnored private var unsyncedIDs: [Zone: Set<UUID>] = [:]

    func unsynced(in zone: Zone) -> Set<UUID> {
        guard let summary = unsyncedSummaries[zone], summary.count > 0 else { return [] }
        if let ids = unsyncedIDs[zone] { return ids }
        let ids = (try? observed[zone]?.storage.store.pendingIDs()) ?? []
        unsyncedIDs[zone] = ids
        return ids
    }

    /// The error from the latest save, cleared by the next one that succeeds.
    @ObservationIgnored private var saveFailure: RecordsError?
    /// A stored record that no longer decodes, which fetches skip, until it decodes again or is deleted.
    @ObservationIgnored private var undecodable: RecordsError?

    private struct Change: Sendable {
        let zone: Zone
        /// The table of the records the change touches, so views can lay it over their results.
        var table: String? = nil
        var sequence: Int
        let source: ObjectIdentifier?
        /// What the change leaves a single record as, so `hasChanges(in:)` can see it before it commits.
        var latest: Latest? = nil
        /// Which records of the table a delete by predicate removes.
        var deletes: (@Sendable (Any) -> Bool)? = nil
        /// The record's stored fields when its first unsaved edit was made, which the save merges against.
        var base: SyncFields? = nil
        /// The fields where the edit kept its value over a change from elsewhere, until it saves.
        var clashes: Set<String> = []
        var run: @Sendable (ZoneStorage) throws -> Void
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
        /// What undoes the commit, when the context journals for undo and the commit changed something.
        var undo: SaveStep? = nil
    }

    /// What one save changed in each zone, which `undo(_:)` puts back.
    struct SaveStep: Sendable {
        let journals: [(zone: Zone, journal: RecordStore.Journal)]
    }

    /// How long the app must be away before becoming active again syncs, five minutes by default. A
    /// shorter absence only picks up changes other processes wrote. Pushes from the server sync
    /// whenever they arrive.
    @ObservationIgnored public var resumeSyncInterval: TimeInterval = 300
    /// When the app last stopped being active.
    @ObservationIgnored var leftAt: Date?

    /// Hears what undoes each save, which turns on journaling. `undoManager` sets it.
    @ObservationIgnored var registerUndo: ((SaveStep) -> Void)?

    #if canImport(Darwin)
    /// Makes each save one step to undo and redo, rather than each edit. Undo puts back what the latest
    /// save changed, cascades included, and commits that as a save of its own, which syncs. Edits that
    /// haven't saved aren't steps, and stay laid over what undo brings back. `nil`, the default, turns
    /// undo off, and saves then skip the bookkeeping.
    ///
    /// ```swift
    /// @Environment(\.undoManager) private var undoManager
    /// .onAppear { context.undoManager = undoManager }
    /// ```
    @ObservationIgnored public var undoManager: UndoManager? {
        didSet {
            registerUndo = undoManager.map { manager in
                { [weak self, weak manager] step in
                    guard let self, let manager else { return }
                    self.register(step, with: manager)
                }
            }
        }
    }

    private func register(_ step: SaveStep, with manager: UndoManager) {
        // Without event grouping, an action needs a group of its own.
        let opensGroup = !manager.groupsByEvent && manager.groupingLevel == 0
        if opensGroup { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { context in
            MainActor.assumeIsolated { try? context.undo(step) }
        }
        if opensGroup { manager.endUndoGrouping() }
    }
    #endif

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
            self?.willResignActive()
        }, becomeActive: { [weak self] in
            self?.resume()
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
        var summaries: [Zone: RecordStore.PendingSummary] = [:]
        for (zone, entry) in observed where entry.storage.sync != nil {
            if let summary = try? entry.storage.store.pendingSummary(), summary.count > 0 {
                summaries[zone] = summary
            }
        }
        if summaries != unsyncedSummaries {
            for zone in Set(summaries.keys).union(unsyncedSummaries.keys) where summaries[zone] != unsyncedSummaries[zone] {
                unsyncedIDs[zone] = nil
            }
            unsyncedSummaries = summaries
        }
        let count = summaries.values.reduce(0) { $0 + $1.count }
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
        rebasePendingEdits(in: zone, storage: storage)
        didChange()
    }

    /// Brings unsaved edits in the zone up to date with what was committed elsewhere, so views show the
    /// fields another save or a sync changed while each edit keeps its own changes. An edit of a record
    /// deleted elsewhere is dropped, since a delete wins. A `@Recordable` showing it keeps the edit for
    /// its user to save again or let go.
    private func rebasePendingEdits(in zone: Zone, storage: ZoneStorage) {
        for (key, change) in pending where change.zone == zone {
            guard case .saved(let record)? = change.latest else { continue }
            if Self.isGone(record, change, in: storage) {
                pending[key] = nil
            } else if let rebased = try? Self.rebased(record, change, in: storage) {
                pending[key] = rebased
            }
        }
    }

    /// Whether the record was stored when its edit began and no longer is.
    private static func isGone<R: Record>(_ record: R, _ change: Change, in storage: ZoneStorage) -> Bool {
        change.base != nil && (try? storage.storedFields(R.self, id: record.id)) == .some(nil)
    }

    private static func rebased<R: Record>(_ record: R, _ change: Change, in storage: ZoneStorage) throws -> Change? {
        guard let base = change.base, let (edit, newBase, clashes) = try storage.rebase(record, base: base) else {
            return nil
        }
        var rebased = change
        rebased.latest = .saved(edit)
        rebased.base = newBase
        rebased.clashes.formUnion(clashes)
        rebased.run = { try $0.save(edit, base: newBase) }
        return rebased
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
        enqueueSave(record, in: zone, source: source)
    }

    /// Inserts an edit made away from the context, such as a draft's, that began from `base`.
    func insert<R: Record>(_ record: R, in zone: Zone, source: ObjectIdentifier?, base: SyncFields?) {
        enqueueSave(record, in: zone, source: source, startingFrom: .some(base))
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

    /// When the context saves on its own.
    public enum Autosave: Equatable, Sendable {
        /// Saves as the app stops being active, such as when the user switches apps or locks the device, so
        /// nothing entered is lost if the system ends the app in the background. The default.
        case whenInactive
        /// Also saves, and with a sync provider sends, once edits have paused this long, so a long editing
        /// session reaches the server without a Save button. It still saves when the app becomes inactive.
        case after(Duration)
    }

    /// When the context saves on its own, `.whenInactive` by default. `.after(.seconds(5))` also saves once
    /// edits pause, and `nil` leaves every save to you. Drafts held by `@Recordable(.draft)` aren't in the
    /// context, so no automatic save commits them.
    public var autosave: Autosave? = .whenInactive {
        didSet { scheduleAutosave() }
    }

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    /// Starts the pause again after each change. A save that fails leaves the changes pending, as any
    /// failed save does, and the next edit tries again.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard case .after(let delay)? = autosave, !pending.isEmpty else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            try? await save()
        }
    }

    /// Commits every pending change, in one transaction for each zone they touch. If the save fails, the
    /// changes stay pending so you can fix the cause and save again, or discard them with `rollback()`.
    public func save() throws {
        guard let batch = takePending() else {
            waitForSaves()
            return
        }
        let container = container
        let journaling = registerUndo != nil
        let result = writer.sync { Result { try Self.commit(batch.changes, in: container, journaling: journaling) } }
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

    /// Picks up other processes' changes as the app becomes active, and after a long enough absence syncs
    /// with the server. It never saves: leaving already did.
    func resume(now: Date = Date()) {
        refresh()
        guard let leftAt, now.timeIntervalSince(leftAt) >= resumeSyncInterval else { return }
        self.leftAt = nil
        let storages = observed.values.map(\.storage).filter { $0.sync != nil }
        guard !storages.isEmpty else { return }
        Task {
            for storage in storages {
                try? await storage.sync?.refresh()
            }
            for storage in storages {
                zoneDidCommit(storage.zone)
            }
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
        let journaling = registerUndo != nil
        let result = await withCheckedContinuation { continuation in
            writer.async {
                continuation.resume(returning: Result { try Self.commit(changes, in: container, journaling: journaling) })
            }
        }
        savesInFlight -= 1
        try finish(batch, result, keepingFailures: keepingFailures)
    }

    /// Commits each zone's changes in a transaction of its own, zone by zone in the order they were first made.
    private nonisolated static func commit(_ changes: [Change], in container: RecordContainer, journaling: Bool) throws -> Commit {
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
        var journals: [(zone: Zone, journal: RecordStore.Journal)] = []
        for zone in zones {
            let storage = try container.storage(for: zone)
            let structure = storage.structureVersion
            let journal = try journaled(journaling, storage) {
                try storage.transaction {
                    bases[zone] = storage.commitCount
                    for change in byZone[zone]! {
                        try change.run(storage)
                    }
                }
            }
            journals += journal.map { [(zone, $0)] } ?? []
            changedStructure = changedStructure || storage.structureVersion != structure
        }
        return Commit(bases: bases, changedStructure: changedStructure, undo: journals.isEmpty ? nil : SaveStep(journals: journals))
    }

    /// Runs `body`, journaling what it changes when asked. Returns the journal unless it's empty.
    private nonisolated static func journaled(
        _ journaling: Bool, _ storage: ZoneStorage, _ body: () throws -> Void
    ) throws -> RecordStore.Journal? {
        guard journaling else {
            try body()
            return nil
        }
        let journal = try storage.store.journaling(body).journal
        return journal.isEmpty ? nil : journal
    }

    /// Puts back what a save changed, in one commit for each zone, and registers what redoes it. Unsaved
    /// changes stay pending, laid over the result.
    func undo(_ step: SaveStep) throws {
        waitForSaves()
        let container = container
        let journaling = registerUndo != nil
        let result = writer.sync {
            Result {
                var bases: [Zone: Int] = [:]
                var changedStructure = false
                var journals: [(zone: Zone, journal: RecordStore.Journal)] = []
                // The last zone saved is the first put back.
                for (zone, journal) in step.journals.reversed() {
                    let storage = try container.storage(for: zone)
                    let structure = storage.structureVersion
                    let inverse = try Self.journaled(journaling, storage) {
                        try storage.transaction {
                            bases[zone] = storage.commitCount
                            try storage.store.restore(journal)
                        }
                    }
                    journals += inverse.map { [(zone, $0)] } ?? []
                    changedStructure = changedStructure || storage.structureVersion != structure
                }
                return Commit(bases: bases, changedStructure: changedStructure, undo: journals.isEmpty ? nil : SaveStep(journals: journals))
            }
        }
        try finish(Batch(taken: [:], changes: []), result, keepingFailures: { _ in false })
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
            let fromElsewhere = base != knownCommits[zone] || commits > base + 1
            outside = outside || fromElsewhere
            knownCommits[zone] = commits
            if fromElsewhere, let storage = observed[zone]?.storage {
                rebasePendingEdits(in: zone, storage: storage)
            }
        }
        let sources = Set(batch.changes.map(\.source))
        lastSaveSource = !outside && sources.count == 1 && !commit.changedStructure ? sources.first! : nil
        didChange()
        if let step = commit.undo {
            registerUndo?(step)
        }
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

    /// Fetches the records the descriptor matches in its order, with this context's unsaved changes laid
    /// over them, so results include your own edits without saving them.
    public func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
        let storage = try storage(for: zone)
        guard hasUnsavedChanges(to: R.table, in: zone) else { return try storage.fetch(descriptor) }
        // Unsaved records can move a page's bounds, so the page is cut after laying them over every match.
        var all = descriptor
        all.fetchLimit = nil
        all.fetchOffset = nil
        let predicate = descriptor.predicate
        let records = overlay(try storage.fetch(all), in: zone, order: RecordOrder(descriptor.sortBy)) {
            (try? predicate?.evaluate($0)) ?? true
        }
        return Array(records.dropFirst(descriptor.fetchOffset ?? 0).prefix(descriptor.fetchLimit ?? .max))
    }

    /// Fetches every record of the type, sorted by ID, with unsaved changes laid over them.
    public func fetch<R: Record>(_ type: R.Type) throws -> [R] {
        try fetch(RecordDescriptor<R>())
    }

    /// Counts the records the descriptor matches, unsaved changes included, in SQL when the predicate
    /// translates and nothing of the type is unsaved.
    public func fetchCount<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> Int {
        guard hasUnsavedChanges(to: R.table, in: zone) else { return try storage(for: zone).fetchCount(descriptor) }
        return try fetch(descriptor).count
    }

    /// Returns the IDs of the records the descriptor matches in its order, unsaved changes included,
    /// without loading the records when the predicate and sort translate to SQL and nothing of the type
    /// is unsaved.
    public func fetchIdentifiers<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [UUID] {
        guard hasUnsavedChanges(to: R.table, in: zone) else {
            return try storage(for: zone).fetchIdentifiers(descriptor)
        }
        return try fetch(descriptor).map(\.id)
    }

    /// Whether changes to the table in the zone are waiting to save or saving now.
    private func hasUnsavedChanges(to table: String, in zone: Zone) -> Bool {
        let matches = { (change: Change) in change.zone == zone && (change.table == table || change.table == nil) }
        return pending.values.contains(where: matches) || inFlight.values.contains(where: matches)
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

    /// The stored copy of a record whose unsaved edit conflicted with a change from elsewhere, or `nil` when
    /// there's no conflict. A sync or another context changed a field the edit had also changed, and the
    /// edit kept its value. The conflict lasts until the edit saves, is rolled back, or is resolved.
    public func conflict<R: Record>(_ type: R.Type = R.self, for id: R.ID) -> R? {
        conflict(type, for: id, in: zone)
    }

    /// Whether the record's unsaved edit conflicted with a change from elsewhere at this property.
    public func conflict<R: Record>(_ type: R.Type = R.self, for id: R.ID, at keyPath: PartialKeyPath<R>) -> Bool {
        conflict(type, for: id, at: keyPath, in: zone)
    }

    /// Settles a record's conflict. `.ours` keeps the edit's values, and `.theirs` takes the stored copy's
    /// values at the fields in conflict. Either way the edit stays unsaved and the conflict clears.
    public func resolveConflict<R: Record>(_ type: R.Type = R.self, for id: R.ID, favoring side: MergeSide) {
        resolveConflict(type, for: id, favoring: side, in: zone)
    }

    func conflict<R: Record>(_ type: R.Type, for id: R.ID, in zone: Zone) -> R? {
        guard pending[Self.key(type, id: id, in: zone)]?.clashes.isEmpty == false else { return nil }
        return try? storage(for: zone).fetch(type, id: id)
    }

    func conflict<R: Record>(_ type: R.Type, for id: R.ID, at keyPath: PartialKeyPath<R>, in zone: Zone) -> Bool {
        guard let clashes = pending[Self.key(type, id: id, in: zone)]?.clashes, !clashes.isEmpty else { return false }
        return R.cachedSchema.fields.contains { $0.keyPath == keyPath && clashes.contains($0.name) }
    }

    func resolveConflict<R: Record>(_ type: R.Type, for id: R.ID, favoring side: MergeSide, in zone: Zone) {
        let key = Self.key(type, id: id, in: zone)
        guard var change = pending[key], !change.clashes.isEmpty else { return }
        if side == .theirs, case .saved(let latest as R)? = change.latest, let stored = try? storage(for: zone).fetch(type, id: id) {
            var record = latest
            for field in R.cachedSchema.fields where change.clashes.contains(field.name) {
                _ = RecordStore.copy(field.keyPath, from: stored, into: &record)
            }
            let base = change.base
            let resolved = record
            change.latest = .saved(resolved)
            change.run = { try $0.save(resolved, base: base) }
            sequence += 1
            change.sequence = sequence
        }
        change.clashes = []
        pending[key] = change
        // Views refetch, including the one whose edit this is.
        lastSaveSource = nil
        didChange()
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

    /// The saved record's version, modification time and tag, or `nil` when the store doesn't hold it.
    /// Unsaved changes have no metadata until they're saved.
    public func metadata<R: Record>(_ type: R.Type, id: R.ID) throws -> RecordMetadata? {
        try storage(for: zone).metadata(type, id: id)
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
            enqueueSave(record, in: zone, source: source)
        }
        return order.sorted(records)
    }

    private static func key<R: Record>(_ record: R, in zone: Zone) -> String {
        key(R.self, id: record.id, in: zone)
    }

    private static func key<R: Record>(_ type: R.Type, id: R.ID, in zone: Zone) -> String {
        "\(zone.name)|record|\(R.table)|\(id)"
    }

    /// Queues a save of the record. Its first unsaved edit keeps the stored fields as the base the edit
    /// started from, and later edits keep that base until the save, so the save merges three-way: fields
    /// another save or a sync changed in the meantime keep their change unless the edit changed them too.
    /// A record not yet stored has no base, and saves whole.
    private func enqueueSave<R: Record>(
        _ record: R, in zone: Zone, source: ObjectIdentifier?, startingFrom given: SyncFields?? = nil
    ) {
        let key = Self.key(record, in: zone)
        let base: SyncFields?
        let earlierClashes = pending[key]?.clashes
        var record = record
        if let given {
            // An edit made away from the context, such as a draft, merges into another view's unsaved edit
            // of the record rather than replace it.
            if let given, let earlier = pending[key], case .saved(let other as R)? = earlier.latest,
               let merged = try? storage(for: zone).merge(record, into: other, base: given) {
                record = merged
                base = earlier.base
            } else {
                base = given
            }
        } else if let earlier = pending[key] ?? inFlight[key] {
            // A later edit, even one made while the earlier edit saves, started from the same copy.
            base = earlier.base
        } else {
            base = try? storage(for: zone).storedFields(R.self, id: record.id)
        }
        let saving = record
        enqueue(key: key, zone: zone, table: R.table, source: source, latest: .saved(saving), base: base) {
            try $0.save(saving, base: base)
        }
        // A later edit keeps the earlier edit's conflict, except at fields it has come to agree with the
        // stored copy, until it saves or is resolved.
        if let clashes = earlierClashes, !clashes.isEmpty {
            pending[key]?.clashes = (try? storage(for: zone).remainingClashes(of: saving, in: clashes)) ?? clashes
        }
    }

    private func enqueue(
        key: String, zone: Zone, table: String? = nil, source: ObjectIdentifier?, latest: Latest? = nil,
        deletes: (@Sendable (Any) -> Bool)? = nil, base: SyncFields? = nil,
        _ run: @escaping @Sendable (ZoneStorage) throws -> Void
    ) {
        // Watch the zone from now on, so commits elsewhere refresh views.
        _ = try? storage(for: zone)
        sequence += 1
        pending[key] = Change(
            zone: zone, table: table, sequence: sequence, source: source, latest: latest, deletes: deletes, base: base, run: run
        )
        // Views show unsaved changes at once.
        notifyHandlers()
        scheduleAutosave()
    }

    /// Whether a save that failed this way may succeed later without anything changing.
    static func isTransient(_ error: Error) -> Bool {
        guard case .database(let code, _)? = error as? RecordsError else { return false }
        // SQLITE_BUSY, LOCKED, READONLY, IOERR, FULL and CANTOPEN, including their extended codes.
        return [5, 6, 8, 10, 13, 14].contains(code & 0xFF)
    }

    /// Saves as the app stops being active, unless automatic saves are off, and notes when it left.
    func willResignActive() {
        if autosave != nil {
            saveBeforeLeaving()
        }
        leftAt = Date()
    }

    /// Saves everything pending when the app stops being active, such as when the user switches apps, so
    /// nothing entered is lost. It can't wait for an async save. A failure keeps the changes pending for
    /// the next `save()` and sets `lastSaveError`.
    func saveBeforeLeaving() {
        guard let batch = takePending() else { return }
        let container = container
        let journaling = registerUndo != nil
        let result = writer.sync { Result { try Self.commit(batch.changes, in: container, journaling: journaling) } }
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
