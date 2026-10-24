import Foundation

/// The order a list of records comes in: by its sort descriptors, then by ID, so ties and lists without
/// descriptors are always in the same order.
struct RecordOrder<R: Record> {
    let descriptors: [SortDescriptor<R>]

    init(_ descriptors: [SortDescriptor<R>]) {
        self.descriptors = descriptors
    }

    func areInOrder(_ first: R, _ second: R) -> Bool {
        for descriptor in descriptors {
            switch descriptor.compare(first, second) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return first.id.precedes(second.id)
    }

    func sorted(_ records: [R]) -> [R] {
        records.sorted(by: areInOrder)
    }

    /// The SQL `ORDER BY` terms, ending with the ID, or nil when a descriptor must sort in Swift. Numbers
    /// and dates sort the same in SQLite as in Swift. Strings don't: `SortDescriptor` compares them with a
    /// localized comparator by default, which SQLite can't match.
    var columns: [(column: String, descending: Bool)]? {
        var columns: [(column: String, descending: Bool)] = []
        for descriptor in descriptors {
            guard let field = R.cachedSchema.fields.first(where: { Self.sortsInSQL($0, as: descriptor) }) else { return nil }
            columns.append((field.name, descriptor.order == .reverse))
        }
        return columns
    }

    /// Whether the descriptor sorts by this field, and the field is a stored number or date.
    private static func sortsInSQL(_ field: RecordSchema<R>.Field, as descriptor: SortDescriptor<R>) -> Bool {
        guard field.inverse == nil, !field.isAsset, field.timestamp != .synced, field.name != "id" else { return false }
        let keyPath = field.keyPath
        return matches(keyPath, Int.self, descriptor) || matches(keyPath, Int64.self, descriptor)
            || matches(keyPath, Int32.self, descriptor) || matches(keyPath, Int16.self, descriptor)
            || matches(keyPath, Int8.self, descriptor) || matches(keyPath, UInt32.self, descriptor)
            || matches(keyPath, UInt16.self, descriptor) || matches(keyPath, UInt8.self, descriptor)
            || matches(keyPath, Double.self, descriptor) || matches(keyPath, Float.self, descriptor)
            || matches(keyPath, Date.self, descriptor)
    }

    /// Whether the descriptor is the one for this key path, plain or optional, in the descriptor's order.
    /// SQLite puts `NULL` first in ascending order, as `SortDescriptor` puts `nil`.
    private static func matches<Value: Comparable>(_ keyPath: AnyKeyPath, _ type: Value.Type, _ descriptor: SortDescriptor<R>) -> Bool {
        // Key paths to stored properties hold no state, so sending one is safe.
        if let keyPath = keyPath as? KeyPath<R, Value> {
            return SortDescriptor(unsafeBitCast(keyPath, to: (any KeyPath<R, Value> & Sendable).self), order: descriptor.order) == descriptor
        }
        if let keyPath = keyPath as? KeyPath<R, Value?> {
            return SortDescriptor(unsafeBitCast(keyPath, to: (any KeyPath<R, Value?> & Sendable).self), order: descriptor.order) == descriptor
        }
        return false
    }
}
