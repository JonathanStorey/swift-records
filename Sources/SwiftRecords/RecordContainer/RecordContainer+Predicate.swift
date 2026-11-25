import Foundation
import Versioning

/// A SQL condition on a `record` row, with the values its `?` placeholders bind in order.
/// `isExact` is `true` when the condition keeps exactly the rows the Swift expression it
/// came from accepts, and `false` when it may keep more.
typealias SQLFilter = (clause: String, values: [Any?], isExact: Bool)

extension RecordContainer {
    /// A SQL condition that keeps every row whose value `predicate` accepts, and usually far
    /// fewer of the others, or `nil` when no part of `predicate` translates.
    ///
    /// SQL narrows and Swift decides: each part SQLite can test reads its value from the row's
    /// JSON with `json_extract`, and each part it cannot is left out, so the condition only
    /// loosens. ``fetch(_:in:predicate:order:)`` still evaluates `predicate` on each value.
    ///
    /// A key path finds where its value is stored by reading it on a placeholder whose values
    /// are unique, from `JSONSchema.placeholder(for:)`. Translated are comparisons of a stored
    /// property with a value, `&&`, `||`, `!`, `nil` checks, a captured list's `contains`, and
    /// a reference list's `contains`. Text compares as SQLite stores it, by its UTF-8 bytes.
    static func filter<T: Decodable>(for predicate: Predicate<T>) -> SQLFilter? {
        guard let schema = PredicateSchema(T.self) else { return nil }
        return (predicate.expression as? any SQLCondition)?.filter(schema)
    }
}

extension Relationship {
    /// SQL that keeps the relationships with a side whose property belongs to `type`, as
    /// `"Note.tags"` belongs to `Note`, and, with `records`, a side whose record is among the
    /// names `records` selects.
    static func filter(type: String? = nil, among records: (clause: String, values: [Any?])?) -> SQLFilter? {
        var clauses: [String] = [], values: [Any?] = []
        if let type {
            clauses.append("(instr(id, ?) = 1 OR instr(id, ?) > 0)")
            values += [type + ".", "~" + type + "."]
        }
        if let records {
            clauses.append("EXISTS (SELECT 1 FROM json_each(COALESCE(ours, base), '$.references') WHERE json_extract(value, '$.recordName') IN (\(records.clause)))")
            values += records.values
        }
        return clauses.isEmpty ? nil : (clauses.joined(separator: " AND "), values, false)
    }
}

// MARK: - Placeholder

/// What a predicate's key paths read on a placeholder `T`, to find where each value is stored.
private struct PredicateSchema {
    /// The record type, as ``RecordContainer/recordType(of:)`` names it.
    let type: String
    let value: Any
    let json: JSONRepresentation
    let scalars: [JSONRepresentation: JSONRepresentation.Path]
    /// A copy of the placeholder for each `Bool` and enum, with only that value changed, and its JSON.
    let flags: [(path: JSONRepresentation.Path, value: Any, json: JSONRepresentation)]

    init?<T: Decodable>(_ type: T.Type) {
        guard let recorded = try? JSONSchema.placeholder(for: type), let json = JSONRepresentation(encoding: recorded.value) else { return nil }
        let flags = recorded.flags.compactMap { flag in JSONRepresentation(encoding: flag.value).map { (flag.path, flag.value as Any, $0) } }
        guard flags.count == recorded.flags.count else { return nil }
        self.type = RecordContainer.recordType(of: type)
        self.value = recorded.value
        self.json = json
        self.scalars = recorded.scalars
        self.flags = flags
    }

    /// The SQL that reads the value at the end of `keyPath` from a row, or `nil` when its
    /// value cannot be told apart, or is not stored where the placeholder holds it.
    func operand(_ keyPath: some PlaceholderReading) -> (clause: String, values: [Any?])? {
        guard keyPath.isStored else { return nil }
        return operand(reading: keyPath.read)
    }

    /// The SQL that reads the stored value `read` takes from the placeholder, or `nil` when
    /// its value cannot be told apart, or is not stored where the placeholder holds it.
    func operand(reading read: (Any) -> Any?) -> (clause: String, values: [Any?])? {
        if let read = read(value), let json = JSONRepresentation(encoding: read),
           let path = scalars[json], self.json[path] == json {
            return path.sqlite.map { ("json_extract(COALESCE(ours, base), ?)", [$0]) }
        }
        // A `Bool` or enum reads differently only on the copy in which its own value changed.
        guard let plain = read(value).flatMap(JSONRepresentation.init(encoding:)) else { return nil }
        for flag in flags {
            guard let changed = read(flag.value).flatMap(JSONRepresentation.init(encoding:)), changed != plain else { continue }
            guard flag.json[flag.path] == changed, json[flag.path] == plain else { return nil }
            return flag.path.sqlite.map { ("json_extract(COALESCE(ours, base), ?)", [$0]) }
        }
        return nil
    }

    /// The SQL that tests whether the reference list at `keyPath` holds `target`, or `nil`
    /// when `keyPath` does not lead to one.
    ///
    /// A list is stored on its record, or as ``Relationship`` records named for its property,
    /// such as `"Note.tags~Tag.notes:…"`. The placeholder cannot tell which, so both are tested.
    func contains(_ keyPath: some PlaceholderReading, _ target: any Encodable) -> SQLFilter? {
        guard let marked = (keyPath.read(value) as? [any Encodable])?.first, case .object(let object) = json else { return nil }
        for (key, list) in object {
            guard case .string(let marker)? = list[[0, "recordName"] as JSONRepresentation.Path],
                  marker == (try? RecordContainer.recordName(for: marked, type: marker.recordType)),
                  let target = try? RecordContainer.recordName(for: target, type: marker.recordType),
                  let path = JSONRepresentation.Path([.key(key)]).sqlite else { continue }
            let property = type + "." + key
            let side = { (index: Int) in "json_extract(COALESCE(other.ours, other.base), '$.references[\(index)].recordName')" }
            return ("""
                (EXISTS (SELECT 1 FROM json_each(COALESCE(ours, base), ?) WHERE json_extract(value, '$.recordName') = ?) \
                OR EXISTS (SELECT 1 FROM record AS other WHERE other.type = ? AND other.zone = record.zone \
                AND other.owner = record.owner AND other.is_deleted = 0 AND (instr(other.id, ?) = 1 OR instr(other.id, ?) > 0) \
                AND ((\(side(0)) = record.id AND \(side(1)) = ?) OR (\(side(1)) = record.id AND \(side(0)) = ?))))
                """, [path, target, RecordContainer.recordType(of: Relationship.self), property + "~", "~" + property + ":", target, target], false)
        }
        return nil
    }
}

private extension String {
    /// The record type a record name begins with, as `"Tag"` in `"Tag:swift"`.
    var recordType: String { String(prefix { $0 != ":" }) }
}

private extension JSONRepresentation.Path {
    /// The path as SQLite's JSON functions read it, with each key quoted, or `nil` for a path
    /// through an array, which a placeholder holds only one element of.
    var sqlite: String? {
        var text = "$"
        for segment in self {
            guard case .key(let key) = segment, !key.contains("\"") else { return nil }
            text += ".\"\(key)\""
        }
        return text
    }
}

private extension JSONRepresentation {
    /// The JSON of `value`, or `nil` when it is not `Encodable` or does not encode.
    init?(encoding value: Any) {
        guard let encodable = value as? any Encodable, let json = try? JSONRepresentation(encodable) else { return nil }
        self = json
    }

    /// A scalar as the SQL that binds it: `NULL`, or `?` with an integer, number or text.
    var operand: (clause: String, values: [Any?])? {
        switch self {
        case .null: ("NULL", [])
        case .bool(let flag): ("?", [flag])
        case .number(let text): Int64(text).map { ("?", [$0]) } ?? Double(text).map { ("?", [$0]) }
        case .string(let text): ("?", [text])
        case .array, .object: nil
        }
    }
}

// MARK: - Expressions

/// A predicate expression that reads a value from the predicate's input.
private protocol PlaceholderReading {
    /// The value this expression reads from `root`, the predicate's input.
    func read(_ root: Any) -> Any?
    /// Whether every step is a stored property, so the value is the one decoded, not computed.
    var isStored: Bool { get }
}

/// A predicate expression whose value SQL can read.
private protocol SQLOperand {
    func operand(_ schema: PredicateSchema) -> (clause: String, values: [Any?])?
}

/// A `Bool` predicate expression that translates to a ``SQLFilter``.
private protocol SQLCondition {
    func filter(_ schema: PredicateSchema) -> SQLFilter?
}

private extension PredicateSchema {
    func filter(_ expression: Any) -> SQLFilter? {
        (expression as? any SQLCondition)?.filter(self)
    }

    func compare(_ lhs: Any, _ operation: String, _ rhs: Any) -> SQLFilter? {
        guard let lhs = (lhs as? any SQLOperand)?.operand(self), let rhs = (rhs as? any SQLOperand)?.operand(self) else { return nil }
        return ("\(lhs.clause) \(operation) \(rhs.clause)", lhs.values + rhs.values, true)
    }
}

extension PredicateExpressions.Variable: PlaceholderReading {
    fileprivate func read(_ root: Any) -> Any? { root }
    fileprivate var isStored: Bool { true }
}

extension PredicateExpressions.KeyPath: PlaceholderReading, SQLOperand, SQLCondition {
    fileprivate func read(_ root: Any) -> Any? {
        ((self.root as? any PlaceholderReading)?.read(root) as? Root.Output)?[keyPath: keyPath]
    }

    fileprivate var isStored: Bool {
        MemoryLayout<Root.Output>.offset(of: keyPath) != nil && (root as? any PlaceholderReading)?.isStored == true
    }

    fileprivate func operand(_ schema: PredicateSchema) -> (clause: String, values: [Any?])? {
        schema.operand(self)
    }

    /// A `Bool` property on its own.
    fileprivate func filter(_ schema: PredicateSchema) -> SQLFilter? {
        guard Output.self == Bool.self, let operand = schema.operand(self) else { return nil }
        return ("\(operand.clause) IS 1", operand.values, true)
    }
}

extension PredicateExpressions.Value: SQLOperand {
    fileprivate func operand(_ schema: PredicateSchema) -> (clause: String, values: [Any?])? {
        JSONRepresentation(encoding: value)?.operand
    }
}

extension PredicateExpressions.NilLiteral: SQLOperand {
    fileprivate func operand(_ schema: PredicateSchema) -> (clause: String, values: [Any?])? { ("NULL", []) }
}

extension PredicateExpressions.Equal: SQLCondition {
    fileprivate func filter(_ schema: PredicateSchema) -> SQLFilter? { schema.compare(lhs, "IS", rhs) }
}

extension PredicateExpressions.NotEqual: SQLCondition {
    fileprivate func filter(_ schema: PredicateSchema) -> SQLFilter? { schema.compare(lhs, "IS NOT", rhs) }
}

extension PredicateExpressions.Comparison: SQLCondition {
    /// Matched by equality, not a `switch`, since Apple's Foundation may add operators, which
    /// are left to Swift.
    fileprivate func filter(_ schema: PredicateSchema) -> SQLFilter? {
        let operations: [(PredicateExpressions.ComparisonOperator, String)] = [(.lessThan, "<"), (.lessThanOrEqual, "<="), (.greaterThan, ">"), (.greaterThanOrEqual, ">=")]
        guard let operation = operations.first(where: { $0.0 == op })?.1 else { return nil }
        return schema.compare(lhs, operation, rhs)
    }
}

extension PredicateExpressions.Conjunction: SQLCondition {
    /// Either side alone still narrows, but no longer exactly.
    fileprivate func filter(_ schema: PredicateSchema) -> SQLFilter? {
        switch (schema.filter(lhs), schema.filter(rhs)) {
        case let (lhs?, rhs?): ("(\(lhs.clause) AND \(rhs.clause))", lhs.values + rhs.values, lhs.isExact && rhs.isExact)
        case let (lhs?, nil): (lhs.clause, lhs.values, false)
        case let (nil, rhs?): (rhs.clause, rhs.values, false)
        case (nil, nil): nil
        }
    }
}

extension PredicateExpressions.Disjunction: SQLCondition {
    /// Both sides must translate, or a row only the other side accepts would be left out.
    fileprivate func filter(_ schema: PredicateSchema) -> SQLFilter? {
        guard let lhs = schema.filter(lhs), let rhs = schema.filter(rhs) else { return nil }
        return ("(\(lhs.clause) OR \(rhs.clause))", lhs.values + rhs.values, lhs.isExact && rhs.isExact)
    }
}

extension PredicateExpressions.Negation: SQLCondition {
    /// Only an exact condition can be negated, since negating a looser one would leave out
    /// rows the predicate accepts. A `NULL`, from a value the row lacks, is kept.
    fileprivate func filter(_ schema: PredicateSchema) -> SQLFilter? {
        guard let wrapped = schema.filter(wrapped), wrapped.isExact else { return nil }
        return ("NOT COALESCE(\(wrapped.clause), 0)", wrapped.values, true)
    }
}

extension PredicateExpressions.SequenceContains: SQLCondition {
    /// A captured list holding a stored property, as in `ids.contains($0.id)`, or a reference
    /// list holding a captured id, as in `$0.tags.contains(tag)`.
    fileprivate func filter(_ schema: PredicateSchema) -> SQLFilter? {
        if let list = sequence as? PredicateExpressions.Value<LHS.Output>, element is any PlaceholderReading,
           case .array(let values)? = JSONRepresentation(encoding: list.value) as JSONRepresentation?,
           values.allSatisfy({ $0.operand != nil && $0 != .null }),
           let element = (element as? any SQLOperand)?.operand(schema) {
            let items = JSONRepresentation.array(values)
            return ("COALESCE(\(element.clause) IN (SELECT value FROM json_each(?)), 0)", element.values + [items.description], true)
        }
        guard let keyPath = sequence as? any PlaceholderReading,
              let target = (element as? PredicateExpressions.Value<RHS.Output>)?.value as? any Encodable else { return nil }
        return schema.contains(keyPath, target)
    }
}

// MARK: - Sort order

extension RecordContainer {
    /// The SQL `ORDER BY` terms that sort rows exactly as `order` sorts their values, or `nil`
    /// when any descriptor cannot be matched exactly.
    ///
    /// A descriptor translates when its key path leads through stored properties to a number,
    /// a `Date`, or a `String`, optional or not. A `String` compared by its own `<` or
    /// `.lexical` sorts by its UTF-8 bytes, as SQLite's `BINARY` does, and one compared
    /// `.localizedStandard` or `.localized` sorts through the collation of the same name,
    /// which calls Foundation's own comparison. Any other type, such as an enum with its own
    /// `<`, has no SQL equal, so the caller sorts in Swift.
    static func orderBy<T: Decodable>(_ order: [SortDescriptor<T>]) -> (clause: String, values: [Any?])? {
        guard let schema = PredicateSchema(T.self) else { return nil }
        var terms: [String] = [], values: [Any?] = []
        for descriptor in order {
            guard let keyPath = descriptor.keyPath, MemoryLayout<T>.offset(of: keyPath) != nil,
                  let collation = collation(for: descriptor, of: type(of: keyPath).valueType),
                  let operand = schema.operand(reading: { ($0 as? T)?[keyPath: keyPath] }) else { return nil }
            // SQLite puts NULL first going up and last going down, as Swift puts `nil`.
            terms.append("\(operand.clause)\(collation) \(descriptor.order == .forward ? "ASC" : "DESC")")
            values += operand.values
        }
        return (terms.joined(separator: ", "), values)
    }

    /// The `COLLATE` clause that compares values of `type` as `descriptor` does, empty for a
    /// number or `Date`, or `nil` when SQL cannot.
    private static func collation<T>(for descriptor: SortDescriptor<T>, of type: Any.Type) -> String? {
        let type = (type as? any OptionalType.Type)?.wrappedType ?? type
        guard type == String.self else {
            let isNumeric = type is any BinaryInteger.Type || type is any BinaryFloatingPoint.Type || type == Date.self
            return isNumeric && descriptor.stringComparator == nil ? "" : nil
        }
        switch descriptor.stringComparator {
        case nil, String.StandardComparator.lexical?: return " COLLATE BINARY"
        // Only Apple's Foundation has the localized comparators.
        #if canImport(Darwin)
        case String.StandardComparator.localizedStandard?: return " COLLATE \(Collation.localizedStandard.rawValue)"
        case String.StandardComparator.localized?: return " COLLATE \(Collation.localized.rawValue)"
        #endif
        default: return nil
        }
    }
}

/// An `Optional` type, so its wrapped type can be read from a metatype.
private protocol OptionalType {
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalType {
    fileprivate static var wrappedType: Any.Type { Wrapped.self }
}
