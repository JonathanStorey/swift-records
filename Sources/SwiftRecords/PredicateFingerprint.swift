import Foundation

/// A hashable summary of a predicate's expression and the values it captured, so `@Records` can tell
/// when a view's filter changed. Two predicates written the same way with the same values match, even
/// though each `#Predicate` gets fresh variable IDs.
enum PredicateFingerprint {
    static func of<R>(_ predicate: Predicate<R>) -> AnyHashable {
        var walker = Walker()
        walker.walk(predicate.variable)
        walker.walk(predicate.expression)
        return AnyHashable(walker.parts)
    }

    private struct Walker {
        var parts: [AnyHashable] = []
        /// Each variable by the order it first appears in.
        var variables: [PredicateExpressions.VariableID: Int] = [:]

        mutating func walk(_ value: Any) {
            if let id = value as? PredicateExpressions.VariableID {
                let index = variables[id] ?? variables.count
                variables[id] = index
                parts.append(AnyHashable(index))
                return
            }
            parts.append(AnyHashable(ObjectIdentifier(type(of: value))))
            // Expressions are walked for their parts. Captured values and key paths compare as themselves.
            if !(value is any PredicateExpression), let hashable = value as? any Hashable {
                parts.append(AnyHashable(hashable))
                return
            }
            let children = Mirror(reflecting: value).children
            guard !children.isEmpty else {
                parts.append(AnyHashable(String(describing: value)))
                return
            }
            parts.append(AnyHashable(children.count))
            for child in children {
                walk(child.value)
            }
        }
    }
}
