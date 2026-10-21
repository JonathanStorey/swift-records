import Foundation
import Observation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The main-actor front door to a `RecordContainer`, in the role SwiftData gives `ModelContext`.
///
/// Inserts, updates and deletes are collected and committed together in one transaction, either when
/// you call `save()` or automatically once edits pause for `autosaveDelay`. Only the latest pending
/// change to each record is kept, so rapid edits such as typing cost one write. Views using `@Records`
/// refresh after each save.
@MainActor
@Observable
public final class RecordsContext {
    public let container: RecordContainer

    /// Incremented after every save. `@Records` observes it to know when to fetch again.
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

    public init(container: RecordContainer) {
        self.container = container
        lifecycle = LifecycleObserver { [weak self] in
            self?.autosave()
        }
        Self.register(self)
    }

    // MARK: Shared contexts

    private struct Registration {
        weak var context: RecordsContext?
        /// Set for contexts that `shared(_:)` created, which nothing else keeps alive.
        var retained: RecordsContext?
    }

    private static var registry: [String: Registration] = [:]

    private static func key(for url: URL?) -> String {
        url?.standardizedFileURL.path ?? "in-memory"
    }

    /// Makes this context the one `shared(_:)` returns for its file, so every view of a zone sees the same
    /// pending changes and refreshes together. The most recently created context for a file wins.
    private static func register(_ context: RecordsContext) {
        registry[key(for: context.container.url)] = Registration(context: context)
    }

    /// The context for a zone's file in `Zone.defaultDirectory`: the most recently created one that is
    /// still alive, or a new one that lives for the rest of the process. `@Records` uses it for a zone
    /// that isn't in the environment.
    public static func shared(_ zone: Zone = .default) throws -> RecordsContext {
        let key = key(for: try zone.url(in: Zone.defaultDirectory))
        if let context = registry[key]?.context {
            return context
        }
        let context = try RecordsContext(zone: zone)
        registry[key] = Registration(context: context, retained: context)
        return context
    }

    /// Opens the zone's container. With no arguments this is the default zone.
    public convenience init(zone: Zone = .default, directory: URL? = nil) throws {
        self.init(container: try RecordContainer(zone: zone, directory: directory))
    }

    /// Opens a container at an exact file location.
    public convenience init(url: URL) throws {
        self.init(container: try RecordContainer(url: url))
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
        try container.transaction {
            for change in changes {
                try change.run(container)
            }
        }
        let sources = Set(changes.map(\.source))
        lastSaveSource = sources.count == 1 && container.structureVersion == structure ? sources.first! : nil
        changeCount += 1
    }

    /// Drops pending changes that have not been saved.
    public func rollback() {
        autosaveTask?.cancel()
        autosaveTask = nil
        pending = [:]
    }

    // MARK: Fetching

    /// Saves pending changes, then fetches, so results always include your own edits.
    public func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        sortBy sortDescriptors: [SortDescriptor<R>] = []
    ) throws -> [R] {
        try save()
        return try container.fetch(type, where: predicate, sortBy: sortDescriptors)
    }

    public func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try save()
        return try container.fetch(type, id: id)
    }

    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try save()
        return try container.fetch(type, ids: ids)
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
