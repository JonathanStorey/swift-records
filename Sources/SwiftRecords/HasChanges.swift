import Foundation

extension RecordContext {
    /// Whether this copy of a record differs from the one the context holds, counting its pending change.
    /// It is true for a record the context has never saved, and false again once an edit is undone.
    ///
    /// ```swift
    /// Button("Save") { context.insert(draft); dismiss() }
    ///     .disabled(!context.hasChanges(draft))
    /// ```
    ///
    /// Related records count, so editing a step makes its recipe changed. Values the container sets
    /// itself, `@Timestamped` properties and inverse relationships, don't. It never saves, so a view can call
    /// it while it updates, and it costs one read by ID each call.
    public func hasChanges<R: Record>(_ record: R) -> Bool {
        guard case .saved(let current)? = try? current(R.self, id: record.id, in: zone), let current = current as? R else {
            return true
        }
        return !record.matches(current)
    }
}

extension BackgroundContext {
    /// Whether this copy of a record differs from the stored one. See `RecordContext.hasChanges(_:)`.
    public func hasChanges<R: Record>(_ record: R) throws -> Bool {
        guard let stored = try self.record(R.self, for: record.id) else { return true }
        return !record.matches(stored)
    }
}

extension Record {
    func matches(_ other: Self) -> Bool {
        CanonicalJSON.$comparing.withValue(true) {
            guard let mine = try? CanonicalJSON.encode(self), let theirs = try? CanonicalJSON.encode(other) else {
                return false
            }
            return mine == theirs
        }
    }

    /// Properties the container sets, which `hasChanges(_:)` leaves out.
    static var containerManagedFields: Set<String> {
        Set(cachedSchema.fields.filter { $0.inverse != nil || $0.timestamp != nil }.map(\.name))
    }
}
