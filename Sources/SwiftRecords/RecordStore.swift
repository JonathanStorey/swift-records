import Foundation

public enum RecordStoreError: Error, Equatable {
    /// A `.deny` relationship still has records, so its owner cannot be deleted.
    case deleteDenied(table: String, field: String)
    /// Records refer to each other through forward properties. Use `@Reference(from:)` for back-pointers.
    case cycle(table: String)
    /// An inverse key path does not name a property of a `@Record` type.
    case unknownInverse(String)
    /// A zone name is empty, starts with a dot, or contains a path separator.
    case invalidZoneName(String)
}

/// The SQLite database behind your records. Thread-safe, and every method is synchronous, so it can be
/// used from the main actor (as `RecordsContext` does) or from any background task.
///
/// Each record type gets its own table. Each relationship property gets a join table named
/// `Owner.property` that keeps the order of both sides.
public final class RecordStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let lock = NSRecursiveLock()
    private var columns: [String: Set<String>] = [:]
    private var relationInfo: [RelationInfo]?
    private var decoding: Set<String> = []

    struct RelationInfo: Equatable {
        let ownerTable: String
        let field: String
        let targetTable: String
        var deleteRule: DeleteRule
        var table: String { ownerTable + "." + field }
    }

    /// The zone this store was opened with, or `nil` when opened by URL.
    public let zone: Zone?

    /// The database file, or `nil` for an in-memory store.
    public let url: URL?

    /// Opens or creates the zone's file. With no arguments this is `default.sqlite` in
    /// `Zone.defaultDirectory`. Pass `directory` to keep zone files somewhere else, such as in tests.
    public convenience init(zone: Zone = .default, directory: URL? = nil) throws {
        let directory = directory ?? Zone.defaultDirectory
        let url = try zone.url(in: directory)
        if url != nil {
            try Zone.prepare(directory)
        }
        try self.init(zone: zone, url: url)
    }

    /// Opens or creates a database file at an exact location.
    public convenience init(url: URL) throws {
        try self.init(zone: nil, url: url)
    }

    private init(zone: Zone?, url: URL?) throws {
        self.zone = zone
        self.url = url
        db = try SQLiteDatabase(url: url)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS "_records_relations" (
                owner_table TEXT NOT NULL, field TEXT NOT NULL, target_table TEXT NOT NULL, delete_rule TEXT NOT NULL,
                PRIMARY KEY (owner_table, field))
            """)
    }

    // MARK: Transactions

    /// Runs `body` atomically. Nested calls join the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            do {
                return try db.transaction(body)
            } catch {
                // DDL rolls back with the transaction, so forget anything we cached about the schema.
                columns = [:]
                relationInfo = nil
                throw error
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Saving

    /// Inserts or updates a record, every record nested inside it, and its relationships.
    public func save<R: Record>(_ record: R) throws {
        try save([record])
    }

    public func save<R: Record>(_ records: [R]) throws {
        try transaction {
            var visited: Set<String> = []
            for record in records {
                try saveRecord(record, visited: &visited)
            }
        }
    }

    private func saveRecord<R: Record>(_ record: R, visited: inout Set<String>) throws {
        let id = try record.sqlID
        guard visited.insert("\(R.table)|\(id)").inserted else { return }
        let encoded = try RecordEncoder.encode(record)

        try ensureTable(R.table)
        try ensureColumns(encoded.columns.map(\.name), in: R.table)
        try upsert(encoded.columns, id: id, into: R.table)

        var linked: Set<String> = []
        for relation in encoded.relations {
            linked.insert(relation.name)
            let info = try ensureRelation(
                owner: R.table, field: relation.name, target: relation.targetType.table,
                deleteRule: R.schema.field(named: relation.name)?.deleteRule ?? .cascade
            )
            for target in relation.targets {
                try saveRecord(target, visited: &visited)
            }
            try link(info, ownerID: id, targets: relation.targets.map { try $0.sqlID })
        }
        // Relations the encoder skipped, such as an optional that is now nil, are unlinked.
        for info in relations() where info.ownerTable == R.table && !linked.contains(info.field) {
            try link(info, ownerID: id, targets: [])
        }

        for (field, ownerIDs) in encoded.inverseOrders {
            try reorderInverse(of: R.self, field: field, targetID: id, ownerIDs: ownerIDs)
        }
    }

    private func upsert(_ values: [(name: String, value: SQLiteValue)], id: SQLiteValue, into table: String) throws {
        var row: [String: SQLiteValue] = [:]
        for (name, value) in values where name != "id" {
            row[name] = value
        }
        // Columns missing from the encoding (nil optionals) are cleared.
        for column in columns[table, default: []] where column != "id" && column != "_position" && row[column] == nil {
            row[column] = .null
        }
        let names = row.keys.sorted()
        let insertColumns = (["id"] + names + ["_position"]).map(quoted).joined(separator: ", ")
        let placeholders = (["?"] + names.map { _ in "?" }).joined(separator: ", ")
        let nextPosition = "(SELECT COALESCE(MAX(\"_position\"), 0) + 1 FROM \(quoted(table)))"
        let conflict = names.isEmpty
            ? "DO NOTHING"
            : "DO UPDATE SET " + names.map { "\(quoted($0)) = excluded.\(quoted($0))" }.joined(separator: ", ")
        try db.run(
            "INSERT INTO \(quoted(table)) (\(insertColumns)) VALUES (\(placeholders), \(nextPosition)) ON CONFLICT(\"id\") \(conflict)",
            [id] + names.map { row[$0]! }
        )
    }

    /// Replaces an owner's links, keeping each target's existing place in its inverse order.
    private func link(_ info: RelationInfo, ownerID: SQLiteValue, targets: [SQLiteValue]) throws {
        let table = quoted(info.table)
        var inversePositions: [SQLiteValue: SQLiteValue] = [:]
        for row in try db.run("SELECT target, inverse_position FROM \(table) WHERE owner = ?", [ownerID]) {
            inversePositions[row["target"]!] = row["inverse_position"]!
        }
        try db.run("DELETE FROM \(table) WHERE owner = ?", [ownerID])

        for (position, target) in targets.enumerated() {
            let inversePosition = try inversePositions[target]
                ?? db.run("SELECT COALESCE(MAX(inverse_position), -1) + 1 AS next FROM \(table) WHERE target = ?", [target])[0]["next"]!
            try db.run(
                "INSERT INTO \(table) (owner, target, position, inverse_position) VALUES (?, ?, ?, ?)",
                [ownerID, target, .integer(Int64(position)), inversePosition]
            )
        }

        guard info.deleteRule == .cascade else { return }
        let kept = Set(targets)
        for removed in inversePositions.keys where !kept.contains(removed) {
            if try !isReferenced(info.targetTable, id: removed) {
                try deleteRow(info.targetTable, id: removed)
            }
        }
    }

    private func reorderInverse<R: Record>(of type: R.Type, field: String, targetID: SQLiteValue, ownerIDs: [SQLiteValue]) throws {
        guard let keyPath = R.schema.field(named: field)?.inverse,
              let info = try inverseRelation(keyPath), tableExists(info.table) else { return }
        for (position, ownerID) in ownerIDs.enumerated() {
            try db.run(
                "UPDATE \(quoted(info.table)) SET inverse_position = ? WHERE owner = ? AND target = ?",
                [.integer(Int64(position)), ownerID, targetID]
            )
        }
    }

    /// Stores the manual order of records of one type, used when a fetch has no sort descriptors.
    public func setOrder<R: Record>(_ ids: [R.ID], for type: R.Type) throws {
        try transaction {
            guard tableExists(R.table) else { return }
            for (position, id) in ids.enumerated() {
                try db.run(
                    "UPDATE \(quoted(R.table)) SET \"_position\" = ? WHERE id = ?",
                    [.integer(Int64(position)), try ValueCoding.encode(id)]
                )
            }
        }
    }

    // MARK: Deleting

    /// Deletes a record and applies each relationship's delete rule.
    public func delete<R: Record>(_ record: R) throws {
        try delete(R.self, id: record.id)
    }

    public func delete<R: Record>(_ type: R.Type, id: R.ID) throws {
        let id = try ValueCoding.encode(id)
        try transaction { try deleteRow(R.table, id: id) }
    }

    /// Deletes by table name, so cascades work for types this process has never loaded.
    private func deleteRow(_ table: String, id: SQLiteValue) throws {
        guard tableExists(table) else { return }
        let owned = relations().filter { $0.ownerTable == table }

        for info in owned where info.deleteRule == .deny {
            if try count(in: info.table, where: "owner", is: id) > 0 {
                throw RecordStoreError.deleteDenied(table: table, field: info.field)
            }
        }
        for info in owned {
            let targets = try db.run("SELECT target FROM \(quoted(info.table)) WHERE owner = ?", [id]).map { $0["target"]! }
            try db.run("DELETE FROM \(quoted(info.table)) WHERE owner = ?", [id])
            guard info.deleteRule == .cascade else { continue }
            for target in targets where try !isReferenced(info.targetTable, id: target) {
                try deleteRow(info.targetTable, id: target)
            }
        }
        for info in relations() where info.targetTable == table {
            try db.run("DELETE FROM \(quoted(info.table)) WHERE target = ?", [id])
        }
        try db.run("DELETE FROM \(quoted(table)) WHERE id = ?", [id])
    }

    private func isReferenced(_ table: String, id: SQLiteValue) throws -> Bool {
        for info in relations() where info.targetTable == table {
            if try count(in: info.table, where: "target", is: id) > 0 { return true }
        }
        return false
    }

    private func count(in table: String, where column: String, is value: SQLiteValue) throws -> Int {
        let rows = try db.run("SELECT COUNT(*) AS n FROM \(quoted(table)) WHERE \(quoted(column)) = ?", [value])
        guard case .integer(let n) = rows.first?["n"] else { return 0 }
        return Int(n)
    }

    // MARK: Fetching

    public func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try fetch(type, ids: [id]).first
    }

    /// Fetches records by ID in the order given, skipping any that no longer exist. Use it to load an
    /// inverse relationship: `store.fetch(ToDo.self, ids: note.todos)`.
    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try locked {
            try ids.compactMap { try fetchRow(R.self, id: ValueCoding.encode($0)) }
        }
    }

    /// Fetches records matching a predicate, sorted by the descriptors or else by their stored order.
    ///
    /// Simple predicates on a record's own properties run as SQL. Anything else is evaluated in memory.
    public func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        sortBy sortDescriptors: [SortDescriptor<R>] = []
    ) throws -> [R] {
        try locked {
            guard tableExists(R.table) else { return [] }
            var sql = "SELECT * FROM \(quoted(R.table))"
            var bindings: [SQLiteValue] = []
            var filterInMemory = false
            if let predicate {
                // A join table that does not exist yet means no links; SQL would fail on it, so filter in memory.
                if let clause = try? PredicateTranslator.translate(predicate),
                   clause.relations.allSatisfy(tableExists) {
                    for (table, column) in clause.columns {
                        try ensureColumns([column], in: table)
                    }
                    sql += " WHERE " + clause.sql
                    bindings = clause.bindings
                } else {
                    filterInMemory = true
                }
            }
            sql += " ORDER BY \"_position\", rowid"

            var records = try db.run(sql, bindings).map { try decodeRow(R.self, row: $0) }
            if filterInMemory, let predicate {
                records = try records.filter { try predicate.evaluate($0) }
            }
            if !sortDescriptors.isEmpty {
                records.sort(using: sortDescriptors)
            }
            return records
        }
    }

    public func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try fetch(type, where: predicate).count
    }

    private func fetchRow<R: Record>(_ type: R.Type, id: SQLiteValue) throws -> R? {
        guard tableExists(R.table),
              let row = try db.run("SELECT * FROM \(quoted(R.table)) WHERE id = ?", [id]).first else { return nil }
        return try decodeRow(R.self, row: row)
    }

    private func decodeRow<R: Record>(_ type: R.Type, row: [String: SQLiteValue]) throws -> R {
        let key = "\(R.table)|\(row["id"] ?? .null)"
        guard decoding.insert(key).inserted else { throw RecordStoreError.cycle(table: R.table) }
        defer { decoding.remove(key) }
        return try R(from: RecordDecoder<R>(row: row, loader: self))
    }

    // MARK: Schema

    private func tableExists(_ table: String) -> Bool {
        if columns[table] != nil { return true }
        let rows = (try? db.run("PRAGMA table_info(\(quoted(table)))")) ?? []
        guard !rows.isEmpty else { return false }
        columns[table] = Set(rows.compactMap { row -> String? in
            if case .text(let name) = row["name"] { return name }
            return nil
        })
        return true
    }

    private func ensureTable(_ table: String) throws {
        guard !tableExists(table) else { return }
        try db.execute("CREATE TABLE \(quoted(table)) (\"id\" PRIMARY KEY, \"_position\" INTEGER)")
        columns[table] = ["id", "_position"]
    }

    /// Adds any missing columns. Columns have no declared type, so SQLite stores each value as given.
    private func ensureColumns(_ names: [String], in table: String) throws {
        try ensureTable(table)
        for name in names where !columns[table, default: []].contains(name) {
            try db.execute("ALTER TABLE \(quoted(table)) ADD COLUMN \(quoted(name))")
            columns[table, default: []].insert(name)
        }
    }

    private func relations() -> [RelationInfo] {
        if let relationInfo { return relationInfo }
        let rows = (try? db.run("SELECT * FROM \"_records_relations\"")) ?? []
        let loaded = rows.compactMap { row -> RelationInfo? in
            guard case .text(let owner) = row["owner_table"], case .text(let field) = row["field"],
                  case .text(let target) = row["target_table"], case .text(let rule) = row["delete_rule"] else { return nil }
            return RelationInfo(ownerTable: owner, field: field, targetTable: target, deleteRule: DeleteRule(rawValue: rule) ?? .cascade)
        }
        relationInfo = loaded
        return loaded
    }

    private func ensureRelation(owner: String, field: String, target: String, deleteRule: DeleteRule) throws -> RelationInfo {
        let info = RelationInfo(ownerTable: owner, field: field, targetTable: target, deleteRule: deleteRule)
        if relations().contains(info) { return info }
        try db.run(
            "INSERT OR REPLACE INTO \"_records_relations\" (owner_table, field, target_table, delete_rule) VALUES (?, ?, ?, ?)",
            [.text(owner), .text(field), .text(target), .text(deleteRule.rawValue)]
        )
        let table = quoted(info.table)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS \(table) (
                owner NOT NULL, target NOT NULL, position INTEGER NOT NULL, inverse_position INTEGER NOT NULL,
                PRIMARY KEY (owner, position));
            CREATE INDEX IF NOT EXISTS \(quoted(info.table + ".target")) ON \(table) (target);
            """)
        relationInfo = relations().filter { !($0.ownerTable == owner && $0.field == field) } + [info]
        return info
    }

    /// Finds the join table behind an inverse key path such as `\ToDo.notes`.
    private func inverseRelation(_ keyPath: AnyKeyPath) throws -> RelationInfo? {
        guard let ownerType = type(of: keyPath).rootType as? any Record.Type,
              let field = fieldName(ownerType, keyPath) else {
            throw RecordStoreError.unknownInverse("\(keyPath)")
        }
        return relations().first { $0.ownerTable == ownerType.table && $0.field == field }
    }

    private func fieldName<O: Record>(_ type: O.Type, _ keyPath: AnyKeyPath) -> String? {
        O.schema.field(for: keyPath)?.name
    }
}

extension RecordStore: RelationLoader {
    func loadRelation(owner table: String, ownerID: SQLiteValue, field: String, targetType: any Record.Type) throws -> [any Record] {
        let relation = quoted(table + "." + field)
        guard hasRelation(owner: table, field: field) else { return [] }
        return try db.run("SELECT target FROM \(relation) WHERE owner = ? ORDER BY position", [ownerID]).compactMap {
            try fetchRow(targetType, id: $0["target"]!)
        }
    }

    func loadInverse(targetID: SQLiteValue, inverse: AnyKeyPath) throws -> [SQLiteValue] {
        guard let info = try inverseRelation(inverse), tableExists(info.table) else { return [] }
        return try db.run(
            "SELECT owner FROM \(quoted(info.table)) WHERE target = ? ORDER BY inverse_position", [targetID]
        ).map { $0["owner"]! }
    }

    func hasRelation(owner table: String, field: String) -> Bool {
        relations().contains { $0.ownerTable == table && $0.field == field }
    }

    func relationCount(owner table: String, ownerID: SQLiteValue, field: String) throws -> Int {
        try count(in: table + "." + field, where: "owner", is: ownerID)
    }
}
