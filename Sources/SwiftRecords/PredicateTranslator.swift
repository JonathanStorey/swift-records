import Foundation

/// Translates a `#Predicate` into a SQL `WHERE` clause.
///
/// Supported: `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, comparisons with `nil`,
/// `String.contains` (iOS 18 and macOS 15), `localizedStandardContains`, and `[values].contains(\.property)` on a record's own
/// stored properties, plus `$0.relationship.contains { ... }` over a to-many relationship, which becomes an
/// `EXISTS` subquery. `RecordContainer` evaluates anything else in memory.
enum PredicateTranslator {
    struct Clause {
        var sql: String
        var bindings: [SQLiteValue]
        /// Columns the clause reads, by table, so the container can add any that do not exist yet.
        var columns: [(table: String, column: String)]
        /// Join tables the clause reads. If one does not exist, the container filters in memory instead.
        var relations: [String]
    }

    struct Unsupported: Error {}

    static func translate<R: Record>(_ predicate: Predicate<R>) throws -> Clause {
        var builder = SQLBuilder()
        builder.scopes[predicate.variable.key] = SQLBuilder.Scope(R.self, alias: R.table)
        let sql = try builder.expression(predicate.expression)
        return Clause(sql: sql, bindings: builder.bindings, columns: builder.columns, relations: builder.relations)
    }
}

struct SQLBuilder {
    /// The table a predicate variable ranges over: the outer record, or a related record inside `contains { }`.
    struct Scope {
        let alias: String
        let table: String
        let fieldName: (AnyKeyPath) -> String?

        init<R: Record>(_ type: R.Type, alias: String) {
            self.alias = alias
            table = R.table
            fieldName = { keyPath in
                guard let field = R.schema.field(for: keyPath), field.inverse == nil else { return nil }
                return field.name
            }
        }
    }

    var scopes: [PredicateExpressions.VariableID: Scope] = [:]
    var bindings: [SQLiteValue] = []
    var columns: [(table: String, column: String)] = []
    var relations: [String] = []
    private var aliasCount = 0

    mutating func expression(_ expression: Any) throws -> String {
        guard let sqlExpression = expression as? SQLExpressible else { throw PredicateTranslator.Unsupported() }
        return try sqlExpression.sql(&self)
    }

    /// Resolves `$0.property` to a qualified column, or to the scope and field name for a relationship.
    func field(_ keyPath: any KeyPathExpression) throws -> (scope: Scope, name: String) {
        guard let scope = scopes[try keyPath.variableKey], let name = scope.fieldName(keyPath.anyKeyPath) else {
            throw PredicateTranslator.Unsupported()
        }
        return (scope, name)
    }

    mutating func column(_ keyPath: any KeyPathExpression) throws -> String {
        let (scope, name) = try field(keyPath)
        columns.append((scope.table, name))
        return "\(quoted(scope.alias)).\(quoted(name))"
    }

    mutating func nextAlias() -> Int {
        aliasCount += 1
        return aliasCount
    }

    mutating func bind(_ value: Any) throws -> String {
        guard let encodable = value as? any Encodable else { throw PredicateTranslator.Unsupported() }
        let encoded = try ValueCoding.encode(encodable)
        // Unsigned values above `Int64.max` are stored as text, which only orders correctly against integers.
        if case .text = encoded, value is UInt64 || value is UInt { throw PredicateTranslator.Unsupported() }
        bindings.append(encoded)
        return "?"
    }
}

protocol SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String
}

/// A key path applied directly to a predicate variable, such as `$0.title`.
protocol KeyPathExpression {
    var variableKey: PredicateExpressions.VariableID { get throws }
    var anyKeyPath: AnyKeyPath { get }
}

extension PredicateExpressions.KeyPath: KeyPathExpression {
    var variableKey: PredicateExpressions.VariableID {
        get throws {
            guard let variable = root as? PredicateExpressions.Variable<Root.Output> else {
                throw PredicateTranslator.Unsupported()
            }
            return variable.key
        }
    }

    var anyKeyPath: AnyKeyPath { keyPath }
}

extension PredicateExpressions.KeyPath: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        try builder.column(self)
    }
}

// `$0.notes.contains { $0.text == "x" }` becomes an EXISTS subquery over the `ToDo.notes` join table.
extension PredicateExpressions.SequenceContainsWhere: SQLExpressible {
    func sql(_ builder: inout SQLBuilder) throws -> String {
        guard let path = sequence as? any KeyPathExpression,
              let targetType = LHS.Output.Element.self as? any Record.Type else {
            throw PredicateTranslator.Unsupported()
        }
        let (outer, field) = try builder.field(path)
        let relation = outer.table + "." + field
        let n = builder.nextAlias()
        let join = quoted("j\(n)")
        let target = SQLBuilder.Scope(targetType, alias: "t\(n)")
        builder.relations.append(relation)
        builder.columns.append((target.table, "id"))
        builder.scopes[variable.key] = target
        let test = try builder.expression(test)
        return "EXISTS (SELECT 1 FROM \(quoted(relation)) AS \(join) "
            + "JOIN \(quoted(target.table)) AS \(quoted(target.alias)) ON \(quoted(target.alias)).\"id\" = \(join).target "
            + "WHERE \(join).owner = \(quoted(outer.alias)).\"id\" AND \(test))"
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
