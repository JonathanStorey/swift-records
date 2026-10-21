import Foundation

extension Record {
    /// Whether this copy differs from the record as the context holds it, counting its pending change.
    /// It is true for a record the context has never saved, and false again once an edit is undone.
    ///
    /// ```swift
    /// Button("Save") { context.save(draft); dismiss() }
    ///     .disabled(!draft.hasChanges(in: context))
    /// ```
    ///
    /// Related records count, so editing a step makes its recipe changed. Values the container sets
    /// itself, `@Timestamp` properties and inverse relationships, don't. It never saves, so a view can call
    /// it while it updates, and it costs one read by ID each call.
    @MainActor
    public func hasChanges(in context: RecordsContext) -> Bool {
        guard case .saved(let current)? = try? context.current(Self.self, id: id), let current = current as? Self else {
            return true
        }
        return !matches(current)
    }

    /// Whether this copy differs from the stored record. See `hasChanges(in:)` for the main context.
    public func hasChanges(in context: BackgroundContext) throws -> Bool {
        guard let stored = try context.fetch(Self.self, id: id) else { return true }
        return !matches(stored)
    }

    private func matches(_ other: Self) -> Bool {
        CanonicalJSON.$comparing.withValue(true) {
            guard let mine = try? CanonicalJSON.encode(self), let theirs = try? CanonicalJSON.encode(other) else {
                return false
            }
            return mine == theirs
        }
    }

    /// Properties the container sets, which `hasChanges(in:)` leaves out.
    static var containerManagedFields: Set<String> {
        Set(schema.fields.filter { $0.inverse != nil || $0.timestamp != nil }.map(\.name))
    }
}
