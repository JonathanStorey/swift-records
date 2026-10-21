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
/// background import or a sync engine.
@MainActor
@Observable
public final class RecordsContext {
    public let container: RecordContainer

    /// Incremented after every save, and after the container commits changes this context didn't make.
    /// `@Records` observes it to know when to fetch again.
    public private(set) var changeCount = 0

    /// When true (the default), pending changes are saved automatically after `autosaveDelay`.
    public var autosaveEnabled = true

    /// How long edits must pause before an autosave. Each new change restarts the wait. The default is
    /// half a second; `.zero` saves on the next turn of the main actor. Pending changes are also saved
    /// by `save()`, by every fetch, and when the app moves to the background.
    public var autosaveDelay: Duration = .milliseconds(500)

    /// The error from the most recent autosave, if it failed.
    public private(set) var lastSaveError: Error?

    private struct Change {
        let sequence: Int
        let source: ObjectIdentifier?
        let run: (RecordContainer) throws -> Void
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

    init(container: RecordContainer) {
        self.container = container
        knownCommits = container.commitCount
        lifecycle = LifecycleObserver { [weak self] in
            self?.autosave()
        }
        commitObserver = container.observeCommits { [weak self] in
            Task { @MainActor in self?.containerDidCommit() }
        }
    }

    deinit {
        if let commitObserver {
            container.removeCommitObserver(commitObserver)
        }
    }

    /// Refreshes views after commits this context didn't make. Its own saves are already counted.
    private func containerDidCommit() {
        let commits = container.commitCount
        guard commits != knownCommits else { return }
        knownCommits = commits
        lastSaveSource = nil
        changeCount += 1
    }

    public var hasChanges: Bool { !pending.isEmpty }

    /// The number of unsaved changes. Repeated edits to one record count once, and storing an array's
    /// order counts as one change.
    public var pendingChangeCount: Int { pending.count }

    // MARK: Changes

    /// Inserts the record, or updates it if one with the same ID exists.
    public func save<R: Record>(_ record: R) {
        enqueue(key: Self.key(record), source: nil) { try $0.save(record) }
    }

    public func delete<R: Record>(_ record: R) {
        enqueue(key: Self.key(record), source: nil) { try $0.delete(record) }
    }

    /// Commits every pending change in one transaction.
    public func save() throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard !pending.isEmpty else { return }
        let changes = pending.values.sorted { $0.sequence < $1.sequence }
        pending = [:]
        let structure = container.structureVersion
        var base = 0
        try container.transaction {
            base = container.commitCount
            for change in changes {
                try change.run(container)
            }
        }
        // Commits from elsewhere since the last refresh, or right after this one, mean views must fetch.
        let commits = container.commitCount
        let outside = base != knownCommits || commits > base + 1
        knownCommits = commits
        let sources = Set(changes.map(\.source))
        lastSaveSource = !outside && sources.count == 1 && container.structureVersion == structure ? sources.first! : nil
        changeCount += 1
    }

    /// Drops pending changes that have not been saved.
    public func rollback() {
        autosaveTask?.cancel()
        autosaveTask = nil
        pending = [:]
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

    public func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try save()
        return try container.fetch(type, id: id)
    }

    /// Saves pending changes, then fetches records by ID in the order given, skipping any that no longer
    /// exist. Use it to load an inverse relationship: `context.fetch(Cookbook.self, ids: recipe.cookbooks)`.
    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try save()
        return try container.fetch(type, ids: ids)
    }

    // MARK: Change tracking

    /// Saves pending changes, then returns the token of the latest change. Store it before you start
    /// reading changes.
    public var changeToken: ChangeToken {
        get throws {
            try save()
            return try container.changeToken
        }
    }

    /// Saves pending changes, then returns each record's latest change after `token`, oldest first. Store
    /// the last change's token and pass it next time.
    public func changes(since token: ChangeToken = .initial) throws -> [RecordChange] {
        try save()
        return try container.changes(since: token)
    }

    /// Removes the log entries of deleted records from before `token`. Entries for existing records stay,
    /// because there is only one per record. A sync layer calls this once the server has the deletes.
    public func pruneChanges(before token: ChangeToken) throws {
        try container.pruneChanges(before: token)
    }

    /// Saves pending changes, then returns a record's version, modification time and tag, or `nil` when
    /// the record doesn't exist.
    public func metadata<R: Record>(_ type: R.Type, id: R.ID) throws -> RecordMetadata? {
        try save()
        return try container.metadata(type, id: id)
    }

    // MARK: Arrays

    /// Applies an edited array of records: new IDs are inserted, missing IDs are deleted, and the
    /// rest are updated. With `keepOrder`, the array's order becomes the stored order. This is what
    /// the `@Records` binding calls when SwiftUI writes to it.
    public func apply<R: Record>(_ records: [R], replacing previous: [R], keepOrder: Bool) {
        apply(records, replacing: previous, keepOrder: keepOrder, source: nil)
    }

    func apply<R: Record>(_ records: [R], replacing previous: [R], keepOrder: Bool, source: ObjectIdentifier?) {
        let kept = Set(records.map(\.id))
        for record in previous where !kept.contains(record.id) {
            enqueue(key: Self.key(record), source: source) { try $0.delete(record) }
        }
        for record in records {
            enqueue(key: Self.key(record), source: source) { try $0.save(record) }
        }
        if keepOrder {
            let ids = records.map(\.id)
            enqueue(key: "order|" + R.table, source: source) { try $0.setOrder(ids, for: R.self) }
        }
    }

    private static func key<R: Record>(_ record: R) -> String {
        "record|\(R.table)|\(record.id)"
    }

    private func enqueue(key: String, source: ObjectIdentifier?, _ run: @escaping (RecordContainer) throws -> Void) {
        sequence += 1
        pending[key] = Change(sequence: sequence, source: source, run: run)
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
            self?.autosave()
        }
    }

    private func autosave() {
        guard autosaveEnabled, !pending.isEmpty else { return }
        do {
            try save()
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }
}

/// Saves pending changes when the app stops being active, so a delayed autosave is never lost.
private final class LifecycleObserver {
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    init(_ handler: @escaping @MainActor @Sendable () -> Void) {
        #if canImport(UIKit) && !os(watchOS)
        let names = [UIApplication.willResignActiveNotification, UIApplication.willTerminateNotification]
        #elseif canImport(AppKit)
        let names = [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification]
        #else
        let names: [Notification.Name] = []
        #endif
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
