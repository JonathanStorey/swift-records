import Foundation

/// Compares two values of one type by their stored properties, without requiring `Equatable`, so an
/// edited array saves only the records that changed. Hashable parts compare with `==`, and an asset
/// compares by its file name without reading the file. A difference it can't see through, such as a
/// dictionary of values that aren't hashable listing its entries in another order, counts as a change,
/// which only costs a save that writes nothing.
enum StructuralEquality {
    static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        guard type(of: lhs) == type(of: rhs) else { return false }
        if let lhs = lhs as? any Hashable {
            return same(lhs, rhs)
        }
        if let lhs = lhs as? any AnyRelationshipStorage, let rhs = rhs as? any AnyRelationshipStorage {
            // What a relationship held when fetched doesn't make it a different value.
            return lhs.records.count == rhs.records.count && zip(lhs.records, rhs.records).allSatisfy { equal($0, $1) }
        }
        let left = Mirror(reflecting: lhs)
        let right = Mirror(reflecting: rhs)
        guard left.children.count == right.children.count else { return false }
        if left.children.isEmpty {
            // Nothing to compare by, such as an object without stored properties.
            return left.displayStyle != .class && String(describing: lhs) == String(describing: rhs)
        }
        return zip(left.children, right.children).allSatisfy { equal($0.value, $1.value) }
    }

    private static func same<H: Hashable>(_ lhs: H, _ rhs: Any) -> Bool {
        (rhs as? H) == lhs
    }
}
