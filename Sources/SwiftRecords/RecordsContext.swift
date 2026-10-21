import Foundation
import Observation

/// The main-actor front door to a `RecordContainer`, in the role SwiftData gives `ModelContext`.
///
/// Inserts, updates and deletes are collected and committed together in one transaction, either when
/// you call `save()` or automatically on the next turn of the main actor. Views using `@Records` refresh
/// after each save.
@MainActor
@Observable
public final class RecordsContext {
    public let container: RecordContainer

    /// Incremented after every save. `@Records` observes it to know when to fetch again.
    public private(set) var changeCount = 0

    /// When true (the default), pending changes are saved on the next turn of the main actor.
    public var autosaveEnabled = true

    /// The error from the most recent autosave, if it failed.
    public private(set) var lastSaveError: Error?

    @ObservationIgnored private var pending: [(RecordContainer) throws -> Void] = []
    @ObservationIgnored private var autosaveScheduled = false

    public init(container: RecordContainer) {
        self.container = container
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

    // MARK: Changes

    /// Inserts the record, or updates it if one with the same ID exists.
    public func save<R: Record>(_ record: R) {
        enqueue { try $0.save(record) }
    }

    public func delete<R: Record>(_ record: R) {
        enqueue { try $0.delete(record) }
    }

    /// Commits every pending change in one transaction.
    public func save() throws {
        guard !pending.isEmpty else { return }
        let changes = pending
        pending = []
        try container.transaction {
            for change in changes {
                try change(container)
            }
        }
        changeCount += 1
    }

    /// Drops pending changes that have not been saved.
    public func rollback() {
        pending = []
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
        let kept = Set(records.map(\.id))
        let removed = previous.filter { !kept.contains($0.id) }
        enqueue { container in
            for record in removed {
                try container.delete(record)
            }
            try container.save(records)
            if keepOrder {
                try container.setOrder(records.map(\.id), for: R.self)
            }
        }
    }

    private func enqueue(_ change: @escaping (RecordContainer) throws -> Void) {
        pending.append(change)
        guard autosaveEnabled, !autosaveScheduled else { return }
        autosaveScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            autosaveScheduled = false
            guard autosaveEnabled else { return }
            do {
                try save()
                lastSaveError = nil
            } catch {
                lastSaveError = error
            }
        }
    }
}
