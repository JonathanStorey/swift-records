import Foundation
import Observation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A container's main-actor context, in the role SwiftData gives `ModelContext`. Get it from
/// `RecordContainer.mainContext`, which every view and caller shares.
///
/// Inserts, updates and deletes are collected and committed together in one transaction, either when
/// you call `save()` or automatically once edits pause for `autosaveDelay`. Only the latest pending
/// change to each record is kept, so rapid edits such as typing cost one write. Views using `@Records`
/// refresh after each save, and after changes written to the container some other way, such as by a
/// background import, a sync engine or an app extension.
///
/// Saving and fetching have `async` versions, which do the database work off the main actor. Use them in
/// async code so the interface keeps running while a background import holds the file.
@MainActor
@Observable
public final class RecordsContext {
    public let container: RecordContainer

    /// Incremented after every save, after a rollback, and after the container commits changes this
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
        let sequence: Int
        let source: ObjectIdentifier?
        /// Stored orders run after every record change, so records inserted in the same save take their places.
        var isOrder = false
        /// What the change leaves a single record as, so `hasChanges(in:)` can see it before it commits.
        var latest: Latest? = nil
        let run: @Sendable (RecordContainer) throws -> Void
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
        /// The container's commit count just before this batch committed.
        let base: Int
        let changedStructure: Bool
    }

    private struct ChangeHandler {
        weak var owner: AnyObject?
        let run: @MainActor () -> Void
    }

    /// Pending changes keyed by what they change, such as one record, so a newer change replaces an older one.
    @ObservationIgnored private var pending: [String: Change] = [:]
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycle: LifecycleObserver?
    /// The single source of every change in the most recent save, when there was one and the save changed
    /// nothing structural. `@Records` uses it to skip fetching again after its own edits.
    @ObservationIgnored private(set) var lastSaveSource: ObjectIdentifier?
    /// The container's commit count as of the last change this context has accounted for.
    @ObservationIgnored private var knownCommits: Int
    @ObservationIgnored private nonisolated(unsafe) var commitObserver: UUID?
    @ObservationIgnored private var changeHandlers: [ObjectIdentifier: ChangeHandler] = [:]
    /// Runs every commit and async read in order, off the main actor, so a save never overtakes an earlier one.
    @ObservationIgnored private let writer = DispatchQueue(label: "SwiftRecords.RecordsContext")
    /// Async saves committing now. Their commits are accounted for when they finish.
    @ObservationIgnored private var savesInFlight = 0 {
        didSet { updateStatus() }
    }

    init(container: RecordContainer) {
        self.container = container
        knownCommits = container.commitCount
        lifecycle = LifecycleObserver(resignActive: { [weak self] in
            self?.autosave()
        }, becomeActive: { [weak self] in
            guard let self else { return }
            if container.sync == nil {
                refresh()
            } else {
                Task { try? await self.refresh() }
            }
        })
        commitObserver = container.observeCommits { [weak self] in
            Task { @MainActor in self?.containerDidCommit() }
        }
        updateStatus()
    }

    deinit {
        if let commitObserver {
            container.removeCommitObserver(commitObserver)
        }
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
            switch container.syncPhase {
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
    private func containerDidCommit() {
        guard savesInFlight == 0 else { return }
        let commits = container.commitCount
        guard commits != knownCommits else { return }
        knownCommits = commits
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

    /// Inserts the record, or updates it if one with the same ID exists.
    public func save<R: Record>(_ record: R) {
        enqueue(key: Self.key(record), source: nil, latest: .saved(record)) { try $0.save(record) }
    }

    public func delete<R: Record>(_ record: R) {
        enqueue(key: Self.key(record), source: nil, latest: .deleted) { try $0.delete(record) }
    }

    public func delete<R: Record>(_ type: R.Type, id: R.ID) {
        enqueue(key: Self.key(type, id: id), source: nil, latest: .deleted) { try $0.delete(type, id: id) }
    }

    /// Deletes every record that matches the predicate when the context saves, applying each one's
    /// delete rules. Without a predicate it deletes every record of the type.
    public func delete<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) {
        enqueue(key: "delete|\(R.table)|\(sequence + 1)", source: nil) { try $0.delete(type, where: predicate) }
    }

    /// Commits every pending change in one transaction. If the save fails, the changes stay pending so
    /// you can fix the cause and save again, or discard them with `rollback()`.
    public func save() throws {
        guard let batch = takePending() else {
            waitForSaves()
            return
        }
        let container = container
        let result = writer.sync { Result { try Self.commit(batch.changes, to: container) } }
        try finish(batch, result, keepingFailures: true)
    }

    /// Commits every pending change in one transaction off the main actor, so the interface keeps running
    /// while it waits for the file. If the save fails, the changes stay pending, as with `save()`.
    ///
    /// With a sync provider, this also sends what the server doesn't have yet. Autosave does too. The
    /// synchronous `save()` only commits, for moments that can't wait, and its changes go with the next send.
    public func save() async throws {
        if let batch = takePending() {
            try await commit(batch, keepingFailures: true)
        } else {
            try await read { _ in }
        }
        await container.sync?.send()
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

    /// Picks up changes another process, such as a widget or app extension, wrote to the zone's file, and
    /// refreshes views if there are any. The context also checks when the app becomes active, and every
    /// save and fetch reads the latest data whether or not you call this.
    public func refresh() {
        container.checkForExternalChanges()
    }

    /// Saves, picks up changes other processes wrote, and with a sync provider, sends what is pending and
    /// fetches the server's changes. It returns once they're stored, so it suits pull-to-refresh. It
    /// throws only what leaves `status` at `failed`: being offline or signed out isn't an error.
    public func refresh() async throws {
        try await save()
        try await read { $0.checkForExternalChanges() }
        try await container.sync?.refresh()
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
        let changes = taken.values.sorted { ($0.isOrder ? 1 : 0, $0.sequence) < ($1.isOrder ? 1 : 0, $1.sequence) }
        return Batch(taken: taken, changes: changes)
    }

    private func commit(_ batch: Batch, keepingFailures: Bool) async throws {
        savesInFlight += 1
        let container = container
        let changes = batch.changes
        let result = await withCheckedContinuation { continuation in
            writer.async {
                continuation.resume(returning: Result { try Self.commit(changes, to: container) })
            }
        }
        savesInFlight -= 1
        try finish(batch, result, keepingFailures: keepingFailures)
    }

    private nonisolated static func commit(_ changes: [Change], to container: RecordContainer) throws -> Commit {
        let structure = container.structureVersion
        var base = 0
        try container.transaction {
            base = container.commitCount
            for change in changes {
                try change.run(container)
            }
        }
        return Commit(base: base, changedStructure: container.structureVersion != structure)
    }

    private func finish(_ batch: Batch, _ result: Result<Commit, Error>, keepingFailures: Bool) throws {
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
        let commits = container.commitCount
        let outside = commit.base != knownCommits || commits > commit.base + 1
        knownCommits = commits
        let sources = Set(batch.changes.map(\.source))
        lastSaveSource = !outside && sources.count == 1 && !commit.changedStructure ? sources.first! : nil
        didChange()
    }

    /// Runs `body` after every save already started, off the main actor.
    private func read<T: Sendable>(_ body: @escaping @Sendable (RecordContainer) throws -> T) async throws -> T {
        let container = container
        return try await withCheckedThrowingContinuation { continuation in
            writer.async {
                continuation.resume(with: Result { try body(container) })
            }
        }
    }

    // MARK: Fetching

    /// Saves pending changes, then fetches records in their stored order, so results always include your
    /// own edits. Simple predicates on a record's own properties run as SQL. Anything else is evaluated
    /// in memory.
    public func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil) throws -> [R] {
        try save()
        return try container.fetch(type, where: predicate)
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
        return try container.fetch(type, where: predicate, limit: limit, offset: offset)
    }

    /// Saves pending changes, then counts in SQL when the predicate translates.
    public func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try save()
        return try container.count(type, where: predicate)
    }

    /// The record as this context holds it: its pending change if it has one, otherwise the stored copy.
    /// Unlike a fetch, it doesn't save, so a view can call it while it updates.
    func current<R: Record>(_ type: R.Type, id: R.ID) throws -> Latest? {
        if let latest = pending[Self.key(type, id: id)]?.latest {
            return latest
        }
        return try container.fetch(type, id: id).map { .saved($0) }
    }

    public func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try save()
        return try container.fetch(type, id: id)
    }

    /// Saves pending changes, then fetches records by ID in the order given, skipping any that no longer
    /// exist.
    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try save()
        return try container.fetch(type, ids: ids)
    }

    /// Saves pending changes, then fetches records by ID in their stored order, skipping any that no longer
    /// exist. Use it to load an inverse relationship: `context.fetch(Cookbook.self, ids: recipe.cookbooks)`.
    public func fetch<R: Record>(_ type: R.Type, ids: Set<UUID>) throws -> [R] {
        try save()
        return try container.fetch(type, ids: ids)
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
            return try container.changeToken
        }
    }

    /// Saves pending changes, then returns each record's latest change after `token`, oldest first. Store
    /// the last change's token and pass it next time.
    package func changes(since token: ChangeToken = .initial) throws -> [RecordChange] {
        try save()
        return try container.changes(since: token)
    }

    /// Saves pending changes, then returns a record's version, modification time and tag, or `nil` when
    /// the record doesn't exist.
    public func metadata<R: Record>(_ type: R.Type, id: R.ID) throws -> RecordMetadata? {
        try save()
        return try container.metadata(type, id: id)
    }

    // MARK: Arrays

    /// Applies an edited array of records: new IDs are inserted, missing IDs are deleted, and the rest
    /// are updated. The array's order becomes the stored order among these records, leaving others in
    /// place. This is what the `@Records` binding calls when SwiftUI writes to it.
    func apply<R: Record>(_ records: [R], replacing previous: [R], source: ObjectIdentifier? = nil) {
        let kept = Set(records.map(\.id))
        for record in previous where !kept.contains(record.id) {
            enqueue(key: Self.key(record), source: source, latest: .deleted) { try $0.delete(record) }
        }
        for record in records {
            enqueue(key: Self.key(record), source: source, latest: .saved(record)) { try $0.save(record) }
        }
        let ids = records.map(\.id)
        enqueue(key: "order|\(R.table)|\(source.map { "\($0)" } ?? "")", source: source, isOrder: true) { try $0.setOrder(ids, for: R.self) }
    }

    private static func key<R: Record>(_ record: R) -> String {
        key(R.self, id: record.id)
    }

    private static func key<R: Record>(_ type: R.Type, id: R.ID) -> String {
        "record|\(R.table)|\(id)"
    }

    private func enqueue(
        key: String, source: ObjectIdentifier?, isOrder: Bool = false, latest: Latest? = nil,
        _ run: @escaping @Sendable (RecordContainer) throws -> Void
    ) {
        sequence += 1
        pending[key] = Change(sequence: sequence, source: source, isOrder: isOrder, latest: latest, run: run)
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
        let result = writer.sync { Result { try Self.commit(batch.changes, to: container) } }
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
        await container.sync?.send()
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
