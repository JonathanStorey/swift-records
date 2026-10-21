import Foundation

/// Translates a `#Predicate` into a SQL `WHERE` clause.
///
/// Supported: `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, comparisons with `nil`,
/// `String.contains` (iOS 18 and macOS 15), `localizedStandardContains`, and `[values].contains(\.property)` on a record's own
/// stored properties. `RecordStore` evaluates anything else in memory.
enum PredicateTranslator {
    struct Clause {
        var sql: String
        var bindings: [SQLiteValue]
        var columns: [String]
    }

    struct Unsupported: Error {}

    static func translate<R: Record>(_ predicate: Predicate<R>) throws -> Clause {
        var builder = SQLBuilder(columnName: { keyPath in
            guard let field = R.schema.field(for: keyPath), field.inverse == nil else { return nil }
            return field.name
        })
        let sql = try builder.expression(predicate.expression)
        return Clause(sql: sql, bindings: builder.bindings, columns: builder.columns)
    }
}

struct SQLBuilder {
    let columnName: (AnyKeyPath) -> String?
    var bindings: [SQLiteValue] = []
    var columns: [String] = []

    mutating func expression(_ expression: Any) throws -> String {
        guard let sqlExpression = expression as? SQLExpressible else { throw PredicateTranslator.Unsupported() }
        return try sqlExpression.sql(&self)
    }

    mutating func column(for keyPath: AnyKeyPath) throws -> String {
        guard let name = columnName(keyPath) else { throw PredicateTranslator.Unsupported() }
        columns.append(name)
        return quoted(name)
    }

    mutating func bind(_ value: Any) throws -> String {
        guard let encodable = value as? any Encodable else { throw PredicateTranslator.Unsupported() }
        bindings.append(try ValueCoding.encode(encodable))
        return "?"
    }
}

protocol SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String
}

/// Marks the predicate's input variable so key paths can check they start from it.
protocol PredicateVariable {}
extension PredicateExpressions.Variable: PredicateVariable {}

extension PredicateExpressions.KeyPath: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        guard root is PredicateVariable else { throw PredicateTranslator.Unsupported() }
        return try builder.column(for: keyPath)
    }
}

extension PredicateExpressions.Value: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        try builder.bind(value)
    }
}

extension PredicateExpressions.NilLiteral: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String { "NULL" }
}

// `IS` matches Swift's equality for optionals, where `nil == nil` is true.
extension PredicateExpressions.Equal: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        "(\(try builder.expression(lhs)) IS \(try builder.expression(rhs)))"
    }
}

extension PredicateExpressions.NotEqual: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        "(\(try builder.expression(lhs)) IS NOT \(try builder.expression(rhs)))"
    }
}

extension PredicateExpressions.Comparison: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        let symbol: String
        switch op {
        case .lessThan: symbol = "<"
        case .lessThanOrEqual: symbol = "<="
        case .greaterThan: symbol = ">"
        case .greaterThanOrEqual: symbol = ">="
        @unknown default: throw PredicateTranslator.Unsupported()
        }
        return "(\(try builder.expression(lhs)) \(symbol) \(try builder.expression(rhs)))"
    }
}

extension PredicateExpressions.Conjunction: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        "(\(try builder.expression(lhs)) AND \(try builder.expression(rhs)))"
    }
}

extension PredicateExpressions.Disjunction: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        "(\(try builder.expression(lhs)) OR \(try builder.expression(rhs)))"
    }
}

extension PredicateExpressions.Negation: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        "(NOT \(try builder.expression(wrapped)))"
    }
}

// `[a, b].contains($0.property)` becomes `property IN (?, ?)`.
extension PredicateExpressions.SequenceContains: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        guard let values = (sequence as? any ValueSequence)?.elements else { throw PredicateTranslator.Unsupported() }
        let element = try builder.expression(element)
        let placeholders = try values.map { try builder.bind($0) }
        return "(\(element) IN (\(placeholders.joined(separator: ", "))))"
    }
}

protocol ValueSequence {
    var elements: [Any] { get }
}

extension PredicateExpressions.Value: ValueSequence where Output: Sequence {
    var elements: [Any] { value.map { $0 } }
}

#if canImport(Darwin)
// Case-insensitive substring match. SQLite's lower() folds ASCII only; other text still matches exactly.
extension PredicateExpressions.StringLocalizedStandardContains: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        "(instr(lower(\(try builder.expression(root))), lower(\(try builder.expression(other)))) > 0)"
    }
}
#endif

// `$0.title.contains("x")`: a case-sensitive substring match.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
extension PredicateExpressions.CollectionContainsCollection: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        "(instr(\(try builder.expression(base)), \(try builder.expression(other))) > 0)"
    }
}
