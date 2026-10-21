import Foundation

public enum RecordContainerError: Error, Equatable {
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
public final class RecordContainer: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let lock = NSRecursiveLock()
    private var columns: [String: Set<String>] = [:]
    private var relationInfo: [RelationInfo]?
    private var decoding: Set<String> = []
    /// Asset files written and released by each open transaction, innermost last.
    private var fileChanges: [(created: [URL], released: [String])] = []
    /// Goes up whenever links change, a row is deleted or an asset file is written: anything a cached copy
    /// of the edited records could not already show.
    private var structuralChanges = 0

    var structureVersion: Int { locked { structuralChanges } }

    struct RelationInfo: Equatable {
        let ownerTable: String
        let field: String
        let targetTable: String
        var deleteRule: DeleteRule
        var table: String { ownerTable + "." + field }
    }

    /// The zone this container was opened with, or `nil` when opened by URL.
    public let zone: Zone?

    /// The database file, or `nil` for an in-memory container.
    public let url: URL?

    /// Where asset files are stored: beside the database file and named after it, such as
    /// `default.assets`. An in-memory container uses a temporary folder that is removed with it.
    public let assetsDirectory: URL

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
        assetsDirectory = url.map { $0.deletingPathExtension().appendingPathExtension("assets") }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("SwiftRecords-\(UUID().uuidString).assets")
        db = try SQLiteDatabase(url: url)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS "_records_relations" (
                owner_table TEXT NOT NULL, field TEXT NOT NULL, target_table TEXT NOT NULL, delete_rule TEXT NOT NULL,
                PRIMARY KEY (owner_table, field));
            CREATE TABLE IF NOT EXISTS "_records_assets" (
                name TEXT PRIMARY KEY, owner_table TEXT NOT NULL, owner_id NOT NULL, field TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS "_records_assets.owner" ON "_records_assets" (owner_table, owner_id);
            """)
    }

    deinit {
        if url == nil {
            try? FileManager.default.removeItem(at: assetsDirectory)
        }
    }

    // MARK: Transactions

    /// Runs `body` atomically. Nested calls join the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            fileChanges.append(([], []))
            do {
                let result = try db.transaction(body)
                let changes = fileChanges.removeLast()
                if fileChanges.isEmpty {
                    removeReleasedFiles(changes.released)
                } else {
                    fileChanges[fileChanges.count - 1].created += changes.created
                    fileChanges[fileChanges.count - 1].released += changes.released
                }
                return result
            } catch {
                // Files written by the rolled-back work go with it, and released ones stay.
                for url in fileChanges.removeLast().created {
                    try? FileManager.default.removeItem(at: url)
                }
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
        var encoded = try RecordEncoder.encode(record)
        encoded.columns += try storeAssets(of: R.self, id: id, assets: encoded.assets)

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

    // MARK: Assets

    /// Writes new asset files and releases the ones a record no longer holds. Returns the asset columns.
    private func storeAssets<R: Record>(of type: R.Type, id: SQLiteValue, assets: [String: Asset]) throws -> [(name: String, value: SQLiteValue)] {
        let fields = Set(R.schema.fields.filter(\.isAsset).map(\.name)).union(assets.keys)
        var columns: [(name: String, value: SQLiteValue)] = []
        for field in fields.sorted() {
            let previous = try db.run(
                "SELECT name FROM \"_records_assets\" WHERE owner_table = ? AND owner_id = ? AND field = ?",
                [.text(R.table), id, .text(field)]
            ).first?["name"]
            var stored: SQLiteValue?
            if let asset = assets[field] {
                stored = .text(try storeAsset(asset, owner: R.table, id: id, field: field))
                columns.append((field, stored!))
            }
            if let previous, case .text(let name) = previous, previous != stored {
                try releaseAsset(named: name)
            }
        }
        return columns
    }

    private func storeAsset(_ asset: Asset, owner table: String, id: SQLiteValue, field: String) throws -> String {
        let owner = try db.run(
            "SELECT owner_table, owner_id, field FROM \"_records_assets\" WHERE name = ?", [.text(asset.name)]
        ).first
        if let owner, owner["owner_table"] == .text(table), owner["owner_id"] == id, owner["field"] == .text(field) {
            return asset.name
        }
        // An asset already held by another record gets its own copy, so deleting one leaves the other.
        let name = owner == nil ? asset.name : Asset.makeName(fileExtension: asset.fileExtension)
        let destination = assetURL(named: name)
        structuralChanges += 1
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let manager = FileManager.default
        switch asset.source {
        case .data(let data):
            try data.write(to: destination, options: .atomic)
            fileChanges[fileChanges.count - 1].created.append(destination)
        case .file(let source):
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: source, to: destination)
            fileChanges[fileChanges.count - 1].created.append(destination)
        case nil:
            // A fetched asset: copy its file unless it is already here, such as one released earlier in this transaction.
            let source = owner == nil ? asset.fileURL : assetURL(named: asset.name)
            if !(owner == nil && manager.fileExists(atPath: destination.path)) {
                guard let source else { throw CocoaError(.fileNoSuchFile) }
                try manager.copyItem(at: source, to: destination)
                fileChanges[fileChanges.count - 1].created.append(destination)
            }
        }
        try db.run(
            "INSERT INTO \"_records_assets\" (name, owner_table, owner_id, field) VALUES (?, ?, ?, ?)",
            [.text(name), .text(table), id, .text(field)]
        )
        return name
    }

    /// Unlinks an asset. Its file is removed once the outermost transaction commits.
    private func releaseAsset(named name: String) throws {
        try db.run("DELETE FROM \"_records_assets\" WHERE name = ?", [.text(name)])
        fileChanges[fileChanges.count - 1].released.append(name)
    }

    private func removeReleasedFiles(_ names: [String]) {
        for name in Set(names) {
            // A released name can be stored again later in the same transaction.
            let held = (try? db.run("SELECT 1 FROM \"_records_assets\" WHERE name = ?", [.text(name)]).isEmpty == false) ?? true
            if !held {
                try? FileManager.default.removeItem(at: assetURL(named: name))
            }
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
        // Skip the write when nothing changed, which is the common case when an edited array is saved.
        if let existing = try db.run("SELECT * FROM \(quoted(table)) WHERE id = ?", [id]).first,
           names.allSatisfy({ existing[$0, default: .null] == row[$0] }) {
            return
        }
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
        var current: [SQLiteValue] = []
        for row in try db.run("SELECT target, inverse_position FROM \(table) WHERE owner = ? ORDER BY position", [ownerID]) {
            inversePositions[row["target"]!] = row["inverse_position"]!
            current.append(row["target"]!)
        }
        guard current != targets else { return }
        structuralChanges += 1
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
                "UPDATE \(quoted(info.table)) SET inverse_position = ? WHERE owner = ? AND target = ? AND inverse_position IS NOT ?",
                [.integer(Int64(position)), ownerID, targetID, .integer(Int64(position))]
            )
        }
    }

    /// Stores the manual order of records of one type, used when a fetch has no sort descriptors.
    public func setOrder<R: Record>(_ ids: [R.ID], for type: R.Type) throws {
        try transaction {
            guard tableExists(R.table) else { return }
            var current: [SQLiteValue: SQLiteValue] = [:]
            for row in try db.run("SELECT id, \"_position\" FROM \(quoted(R.table))") {
                current[row["id"]!] = row["_position"] ?? .null
            }
            for (position, id) in ids.enumerated() {
                let id = try ValueCoding.encode(id)
                let position = SQLiteValue.integer(Int64(position))
                guard let stored = current[id], stored != position else { continue }
                try db.run("UPDATE \(quoted(R.table)) SET \"_position\" = ? WHERE id = ?", [position, id])
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
        structuralChanges += 1
        let owned = relations().filter { $0.ownerTable == table }

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
        let assets = try db.run(
            "SELECT name FROM \"_records_assets\" WHERE owner_table = ? AND owner_id = ?", [.text(table), id]
        )
        for case .text(let name)? in assets.map({ $0["name"] }) {
            try releaseAsset(named: name)
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
    /// inverse relationship: `container.fetch(ToDo.self, ids: note.todos)`.
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
        guard decoding.insert(key).inserted else { throw RecordContainerError.cycle(table: R.table) }
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
            // A rule this version does not know, such as the earlier `nullify` or `deny`, keeps records rather than deleting them.
            return RelationInfo(ownerTable: owner, field: field, targetTable: target, deleteRule: DeleteRule(rawValue: rule) ?? DeleteRule.none)
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
            throw RecordContainerError.unknownInverse("\(keyPath)")
        }
        return relations().first { $0.ownerTable == ownerType.table && $0.field == field }
    }

    private func fieldName<O: Record>(_ type: O.Type, _ keyPath: AnyKeyPath) -> String? {
        O.schema.field(for: keyPath)?.name
    }
}

extension RecordContainer: RelationLoader {
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

    func assetURL(named name: String) -> URL {
        assetsDirectory.appendingPathComponent(name)
    }
}
