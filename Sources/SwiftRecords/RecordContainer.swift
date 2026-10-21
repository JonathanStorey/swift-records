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
    private var decoding: Set<RowKey> = []
    /// Asset files written and released by each open transaction, innermost last.
    private var fileChanges: [(created: [URL], released: [String])] = []
    /// Records logged by each open transaction, innermost last, so a record's version goes up once per save.
    private var logged: [[RowKey: RecordChange.Kind]] = []
    /// Above zero while applying changes from a sync server, which are never logged.
    private var applyingSynced = 0
    /// True once the open transaction has written something a fetch could see.
    private var changedData = false
    /// Goes up with each committed transaction that changed data.
    private var commits = 0
    private var commitObservers: [UUID: @Sendable () -> Void] = [:]
    /// Goes up whenever links change, a row is deleted or an asset file is written: anything a cached copy
    /// of the edited records could not already show.
    private var structuralChanges = 0

    var structureVersion: Int { locked { structuralChanges } }

    struct RelationInfo: Equatable {
        let ownerTable: String
        let field: String
        let targetTable: String
        /// `nil` keeps related records.
        var deleteRule: DeleteRule?
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
            CREATE TABLE IF NOT EXISTS "_records_sync_state" (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS "_records_changes" (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, record_table TEXT NOT NULL, record_id NOT NULL,
                kind TEXT NOT NULL, version INTEGER NOT NULL, time REAL NOT NULL,
                UNIQUE (record_table, record_id));
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
            logged.append([:])
            do {
                let result = try db.transaction(body)
                let changes = fileChanges.removeLast()
                let records = logged.removeLast()
                if fileChanges.isEmpty {
                    removeReleasedFiles(changes.released)
                    if changedData {
                        changedData = false
                        commits += 1
                        commitObservers.values.forEach { $0() }
                    }
                } else {
                    fileChanges[fileChanges.count - 1].created += changes.created
                    fileChanges[fileChanges.count - 1].released += changes.released
                    logged[logged.count - 1].merge(records) { $1 }
                }
                return result
            } catch {
                logged.removeLast()
                if fileChanges.count == 1 {
                    changedData = false
                }
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
            var visited: Set<RowKey> = []
            for record in records {
                try saveRecord(record, visited: &visited)
            }
        }
    }

    private func saveRecord<R: Record>(_ record: R, visited: inout Set<RowKey>) throws {
        let id = try record.sqlID
        guard visited.insert(RowKey(table: R.table, id: id)).inserted else { return }
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
                deleteRule: R.schema.field(named: relation.name).map(\.deleteRule) ?? .cascade
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
        let assetFields = R.schema.fields.filter(\.isAsset)
        let fields = Set(assetFields.map(\.name)).union(assets.keys)
        var columns: [(name: String, value: SQLiteValue)] = []
        for field in fields.sorted() {
            let previous = try db.run(
                "SELECT name FROM \"_records_assets\" WHERE owner_table = ? AND owner_id = ? AND field = ?",
                [.text(R.table), id, .text(field)]
            ).first?["name"]
            var stored: SQLiteValue?
            if let asset = assets[field], let storage = asset.storage {
                let fileExtension = assetFields.first { $0.name == field }?.fileExtension ?? ""
                stored = .text(try storeAsset(storage, fileExtension: fileExtension, owner: R.table, id: id, field: field))
                columns.append((field, stored!))
            }
            if let previous, case .text(let name) = previous, previous != stored {
                try releaseAsset(named: name)
            }
        }
        return columns
    }

    private func storeAsset(
        _ asset: Asset.Storage, fileExtension: String, owner table: String, id: SQLiteValue, field: String
    ) throws -> String {
        // A new asset's name gets the extension from `@Asset(fileExtension:)` if it has none of its own.
        let hasExtension = !(asset.name as NSString).pathExtension.isEmpty
        let fileName = hasExtension || fileExtension.isEmpty ? asset.name : asset.name + "." + fileExtension
        let owner = try db.run(
            "SELECT owner_table, owner_id, field FROM \"_records_assets\" WHERE name = ?", [.text(fileName)]
        ).first
        if let owner, owner["owner_table"] == .text(table), owner["owner_id"] == id, owner["field"] == .text(field) {
            return fileName
        }
        // An asset already held by another record gets its own copy, so deleting one leaves the other.
        let name = owner == nil ? fileName : Asset.makeName(fileExtension: (fileName as NSString).pathExtension)
        let destination = assetURL(named: name)
        structuralChanges += 1
        let manager = FileManager.default
        try manager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        switch asset.source {
        case .data(let data):
            try data.write(to: destination, options: .atomic)
            fileChanges[fileChanges.count - 1].created.append(destination)
        case .file(let source):
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: source, to: destination)
            fileChanges[fileChanges.count - 1].created.append(destination)
        case .stored(let source):
            // A fetched asset: copy its file unless it is already here, such as one released earlier in this transaction.
            if !(owner == nil && manager.fileExists(atPath: destination.path)) {
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
        for column in columns[table, default: []] where !Self.internalColumns.contains(column) && row[column] == nil {
            row[column] = .null
        }
        let names = row.keys.sorted()
        // Skip the write when nothing changed, which is the common case when an edited array is saved.
        if let existing = try db.run("SELECT \(recordColumns(table)) FROM \(quoted(table)) WHERE id = ?", [id]).first,
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
        try logChange(table, id: id)
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
        // In a synced store the links belong to the owner, so changing them is a change to the owner.
        try logChange(info.ownerTable, id: ownerID)
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
        var current: [SQLiteValue: SQLiteValue] = [:]
        for row in try db.run("SELECT owner, inverse_position FROM \(quoted(info.table)) WHERE target = ?", [targetID]) {
            current[row["owner"]!] = row["inverse_position"]!
        }
        for (position, ownerID) in ownerIDs.enumerated() {
            let position = SQLiteValue.integer(Int64(position))
            guard let stored = current[ownerID], stored != position else { continue }
            try db.run(
                "UPDATE \(quoted(info.table)) SET inverse_position = ? WHERE owner = ? AND target = ?",
                [position, ownerID, targetID]
            )
            // The inverse order is the target's own data, so reordering it changes the target.
            try logChange(R.table, id: targetID)
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
                try logChange(R.table, id: id)
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
            // Owners that still link here lose a link, which changes them.
            for row in try db.run("SELECT owner FROM \(quoted(info.table)) WHERE target = ?", [id]) {
                try logChange(info.ownerTable, id: row["owner"]!)
            }
            try db.run("DELETE FROM \(quoted(info.table)) WHERE target = ?", [id])
        }
        let assets = try db.run(
            "SELECT name FROM \"_records_assets\" WHERE owner_table = ? AND owner_id = ?", [.text(table), id]
        )
        for case .text(let name)? in assets.map({ $0["name"] }) {
            try releaseAsset(named: name)
        }
        if try !db.run("SELECT 1 FROM \(quoted(table)) WHERE id = ?", [id]).isEmpty {
            try logChange(table, id: id, kind: .delete)
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
    /// inverse relationship: `container.fetch(Cookbook.self, ids: recipe.cookbooks)`.
    public func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try locked {
            guard tableExists(R.table) else { return [] }
            let ids = try ids.map { try ValueCoding.encode($0) }
            var rows: [SQLiteValue: [String: SQLiteValue]] = [:]
            for chunk in ids.chunked(into: Self.batchSize) {
                for row in try db.run("SELECT \(recordColumns(R.table)) FROM \(quoted(R.table)) WHERE id IN (\(placeholders(chunk.count)))", Array(chunk)) {
                    rows[row["id"]!] = row
                }
            }
            let found = ids.compactMap { rows[$0] }
            return try prefetching(R.table, rows: found) {
                try found.map { try decodeRow(R.self, row: $0) }
            }
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
            var records = try fetchRecords(R.self, where: predicate, page: nil)
            if !sortDescriptors.isEmpty {
                records.sort(using: sortDescriptors)
            }
            return records
        }
    }

    /// Fetches one page of records: at most `limit` of them, starting `offset` records into the results.
    ///
    /// The slice's indices are the records' positions in the full results, so a page fetched with an
    /// offset of 40 starts at index 40. Without sort descriptors the page is read straight from SQL when
    /// the predicate translates. With sort descriptors, every match is loaded and sorted first.
    public func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        sortBy sortDescriptors: [SortDescriptor<R>] = [],
        limit: Int,
        offset: Int = 0
    ) throws -> RecordSlice<R> {
        precondition(limit >= 0 && offset >= 0, "limit and offset must not be negative")
        return try locked {
            if sortDescriptors.isEmpty {
                return RecordSlice(try fetchRecords(R.self, where: predicate, page: (limit, offset)), startIndex: offset)
            }
            let all = try fetchRecords(R.self, where: predicate, page: nil).sorted(using: sortDescriptors)
            let start = min(offset, all.count)
            return RecordSlice(Array(all[start..<min(start + limit, all.count)]), startIndex: offset)
        }
    }

    public func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try locked {
            guard tableExists(R.table) else { return 0 }
            guard let (clause, bindings) = try whereClause(predicate) else {
                return try fetchRecords(R.self, where: predicate, page: nil).count
            }
            let rows = try db.run("SELECT COUNT(*) AS n FROM \(quoted(R.table))\(clause)", bindings)
            guard case .integer(let n) = rows.first?["n"] else { return 0 }
            return Int(n)
        }
    }

    /// The SQL `WHERE` clause for a predicate: empty for none, or nil when it must run in memory.
    private func whereClause<R: Record>(_ predicate: Predicate<R>?) throws -> (String, [SQLiteValue])? {
        guard let predicate else { return ("", []) }
        // A join table that does not exist yet means no links; SQL would fail on it, so filter in memory.
        guard let clause = try? PredicateTranslator.translate(predicate), clause.relations.allSatisfy(tableExists) else {
            return nil
        }
        for (table, column) in clause.columns {
            try ensureColumns([column], in: table)
        }
        return (" WHERE " + clause.sql, clause.bindings)
    }

    /// Loads matching records in stored order, optionally one page of them.
    private func fetchRecords<R: Record>(_ type: R.Type, where predicate: Predicate<R>?, page: (limit: Int, offset: Int)?) throws -> [R] {
        guard tableExists(R.table) else { return [] }
        let translated = try whereClause(predicate)
        var sql = "SELECT \(recordColumns(R.table)) FROM \(quoted(R.table))" + (translated?.0 ?? "") + " ORDER BY \"_position\", rowid"
        var bindings = translated?.1 ?? []
        if let page, translated != nil {
            sql += " LIMIT ? OFFSET ?"
            bindings += [.integer(Int64(page.limit)), .integer(Int64(page.offset))]
        }
        let rows = try db.run(sql, bindings)
        var records = try prefetching(R.table, rows: rows) {
            try rows.map { try decodeRow(R.self, row: $0) }
        }
        if translated == nil, let predicate {
            records = try records.filter { try predicate.evaluate($0) }
            if let page {
                let start = min(page.offset, records.count)
                records = Array(records[start..<min(start + page.limit, records.count)])
            }
        }
        return records
    }

    private func fetchRow<R: Record>(_ type: R.Type, id: SQLiteValue) throws -> R? {
        guard tableExists(R.table) else { return nil }
        if let row = prefetched?.rows[R.table]?[id] {
            return try decodeRow(R.self, row: row)
        }
        guard let row = try db.run("SELECT \(recordColumns(R.table)) FROM \(quoted(R.table)) WHERE id = ?", [id]).first else { return nil }
        return try decodeRow(R.self, row: row)
    }

    // MARK: Batch loading

    /// Rows and links loaded ahead of decoding, so a fetch of many records runs one query per relationship
    /// instead of one per record.
    private final class Prefetch {
        /// Rows by table, then ID.
        var rows: [String: [SQLiteValue: [String: SQLiteValue]]] = [:]
        /// Each owner's targets in order, by join table.
        var links: [String: [SQLiteValue: [SQLiteValue]]] = [:]
        /// Each target's owners in inverse order, by join table.
        var owners: [String: [SQLiteValue: [SQLiteValue]]] = [:]
        /// Rows whose relationships are loaded.
        var visited: Set<RowKey> = []
    }

    private var prefetched: Prefetch?
    private static let batchSize = 500

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Loads every relationship reachable from `rows`, level by level, then runs `body` to decode them.
    private func prefetching<T>(_ table: String, rows: [[String: SQLiteValue]], _ body: () throws -> T) throws -> T {
        let owner = prefetched == nil
        let cache = prefetched ?? Prefetch()
        prefetched = cache
        defer { if owner { prefetched = nil } }

        for row in rows {
            cache.rows[table, default: [:]][row["id"]!] = row
        }
        var frontier = [(table, rows.map { $0["id"]! })]
        while let (table, ids) = frontier.popLast() {
            let ids = ids.filter { cache.visited.insert(RowKey(table: table, id: $0)).inserted }
            guard !ids.isEmpty else { continue }
            for info in relations() where tableExists(info.table) {
                if info.ownerTable == table {
                    var targets: [SQLiteValue] = []
                    for id in ids { cache.links[info.table, default: [:]][id] = [] }
                    for chunk in ids.chunked(into: Self.batchSize) {
                        for link in try db.run(
                            "SELECT owner, target FROM \(quoted(info.table)) WHERE owner IN (\(placeholders(chunk.count))) ORDER BY owner, position",
                            Array(chunk)
                        ) {
                            cache.links[info.table]![link["owner"]!]!.append(link["target"]!)
                            targets.append(link["target"]!)
                        }
                    }
                    let missing = Array(Set(targets).filter { cache.rows[info.targetTable]?[$0] == nil })
                    if tableExists(info.targetTable) {
                        for chunk in missing.chunked(into: Self.batchSize) {
                            for row in try db.run(
                                "SELECT \(recordColumns(info.targetTable)) FROM \(quoted(info.targetTable)) WHERE id IN (\(placeholders(chunk.count)))", Array(chunk)
                            ) {
                                cache.rows[info.targetTable, default: [:]][row["id"]!] = row
                            }
                        }
                    }
                    frontier.append((info.targetTable, Array(Set(targets))))
                }
                if info.targetTable == table {
                    for id in ids { cache.owners[info.table, default: [:]][id] = [] }
                    for chunk in ids.chunked(into: Self.batchSize) {
                        for link in try db.run(
                            "SELECT owner, target FROM \(quoted(info.table)) WHERE target IN (\(placeholders(chunk.count))) ORDER BY target, inverse_position",
                            Array(chunk)
                        ) {
                            cache.owners[info.table]![link["target"]!]!.append(link["owner"]!)
                        }
                    }
                }
            }
        }
        return try body()
    }

    private func decodeRow<R: Record>(_ type: R.Type, row: [String: SQLiteValue]) throws -> R {
        let key = RowKey(table: R.table, id: row["id"] ?? .null)
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
        if !tableExists(table) {
            try db.execute("CREATE TABLE \(quoted(table)) (\"id\" PRIMARY KEY, \"_position\" INTEGER)")
            columns[table] = ["id", "_position"]
        }
        // Tables created before change tracking get its columns the first time they're written.
        for column in ["_version", "_modified", "_tag"] where !columns[table, default: []].contains(column) {
            let definition = column == "_version" ? " INTEGER NOT NULL DEFAULT 0" : ""
            try db.execute("ALTER TABLE \(quoted(table)) ADD COLUMN \(quoted(column))\(definition)")
            columns[table, default: []].insert(column)
        }
    }

    /// Columns records never see: their version, last change and sync tag.
    static let trackingColumns: Set<String> = ["_version", "_modified", "_tag"]
    private static let internalColumns: Set<String> = Set(["id", "_position"]).union(trackingColumns)

    /// The columns a record decodes from, which leaves out the tracking columns so a fetch never loads tags.
    private func recordColumns(_ table: String) -> String {
        columns[table, default: []].subtracting(Self.trackingColumns).sorted()
            .map { quoted(table) + "." + quoted($0) }.joined(separator: ", ")
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
            // Any rule but cascade, including the earlier `nullify` and `deny`, keeps records rather than deleting them.
            return RelationInfo(ownerTable: owner, field: field, targetTable: target, deleteRule: DeleteRule(rawValue: rule))
        }
        relationInfo = loaded
        return loaded
    }

    private func ensureRelation(owner: String, field: String, target: String, deleteRule: DeleteRule?) throws -> RelationInfo {
        let info = RelationInfo(ownerTable: owner, field: field, targetTable: target, deleteRule: deleteRule)
        if relations().contains(info) { return info }
        try db.run(
            "INSERT OR REPLACE INTO \"_records_relations\" (owner_table, field, target_table, delete_rule) VALUES (?, ?, ?, ?)",
            [.text(owner), .text(field), .text(target), .text(deleteRule?.rawValue ?? "none")]
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
        if let targets = prefetched?.links[table + "." + field]?[ownerID] {
            return try targets.compactMap { try fetchRow(targetType, id: $0) }
        }
        return try db.run("SELECT target FROM \(relation) WHERE owner = ? ORDER BY position", [ownerID]).compactMap {
            try fetchRow(targetType, id: $0["target"]!)
        }
    }

    func loadInverse(targetID: SQLiteValue, inverse: AnyKeyPath) throws -> [SQLiteValue] {
        guard let info = try inverseRelation(inverse), tableExists(info.table) else { return [] }
        if let owners = prefetched?.owners[info.table]?[targetID] {
            return owners
        }
        return try db.run(
            "SELECT owner FROM \(quoted(info.table)) WHERE target = ? ORDER BY inverse_position", [targetID]
        ).map { $0["owner"]! }
    }

    func hasRelation(owner table: String, field: String) -> Bool {
        relations().contains { $0.ownerTable == table && $0.field == field }
    }

    func relationCount(owner table: String, ownerID: SQLiteValue, field: String) throws -> Int {
        if let targets = prefetched?.links[table + "." + field]?[ownerID] {
            return targets.count
        }
        return try count(in: table + "." + field, where: "owner", is: ownerID)
    }

    func assetURL(named name: String) -> URL {
        assetsDirectory.appendingPathComponent(name)
    }
}

/// One page of fetched records. Its indices are the records' positions in the full results, so a page
/// fetched with an offset of 40 starts at index 40. It is read-only: edit a record and save it to change it.
public struct RecordSlice<R: Record>: RandomAccessCollection, Sendable {
    private let records: [R]
    public let startIndex: Int

    init(_ records: [R], startIndex: Int) {
        self.records = records
        self.startIndex = startIndex
    }

    public var endIndex: Int { startIndex + records.count }

    public subscript(position: Int) -> R {
        records[position - startIndex]
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

/// A row's identity across tables, for tracking rows already saved or being decoded.
struct RowKey: Hashable {
    let table: String
    let id: SQLiteValue
}

// MARK: Change tracking

extension RecordContainer {
    /// Bumps a record's version and moves its log entry to the end, once per transaction.
    fileprivate func logChange(_ table: String, id: SQLiteValue, kind: RecordChange.Kind = .save) throws {
        changedData = true
        if applyingSynced > 0 {
            // The server already has this change. A record it deleted has nothing left to send.
            if kind == .delete {
                try db.run("DELETE FROM \"_records_changes\" WHERE record_table = ? AND record_id = ?", [.text(table), id])
            }
            return
        }
        let key = RowKey(table: table, id: id)
        if kind == .save, logged.last(where: { $0[key] != nil })?[key] == .save { return }
        logged[logged.count - 1][key] = kind

        let previous = try db.run(
            "SELECT version FROM \"_records_changes\" WHERE record_table = ? AND record_id = ?", [.text(table), id]
        ).first?["version"]
        guard case .integer(let last) = previous ?? .integer(0) else { return }
        let version = SQLiteValue.integer(last + 1)
        let now = SQLiteValue.real(Date().timeIntervalSince1970)
        if kind == .save {
            try db.run("UPDATE \(quoted(table)) SET \"_version\" = ?, \"_modified\" = ? WHERE id = ?", [version, now, id])
        }
        // Replacing the entry gives it a new sequence number at the end of the log.
        try db.run(
            "INSERT OR REPLACE INTO \"_records_changes\" (record_table, record_id, kind, version, time) VALUES (?, ?, ?, ?, ?)",
            [.text(table), id, .text(kind.rawValue), version, now]
        )
    }

    /// The token of the latest change, to store before you start reading changes.
    public var changeToken: ChangeToken {
        get throws {
            try locked {
                let row = try db.run("SELECT seq FROM sqlite_sequence WHERE name = '_records_changes'").first
                guard case .integer(let seq) = row?["seq"] else { return .initial }
                return ChangeToken(rawValue: seq)
            }
        }
    }

    /// Each record's latest change after `token`, oldest first. Store the last change's token and pass it
    /// next time.
    public func changes(since token: ChangeToken = .initial) throws -> [RecordChange] {
        try locked {
            try db.run(
                "SELECT * FROM \"_records_changes\" WHERE seq > ? ORDER BY seq", [.integer(token.rawValue)]
            ).compactMap { row in
                guard case .integer(let seq) = row["seq"], case .text(let table) = row["record_table"],
                      case .text(let kind) = row["kind"], let kind = RecordChange.Kind(rawValue: kind),
                      case .integer(let version) = row["version"], case .real(let time) = row["time"] else { return nil }
                return RecordChange(
                    recordType: table, id: try ValueCoding.decode(UUID.self, from: row["record_id"] ?? .null), kind: kind,
                    version: Int(version), date: Date(timeIntervalSince1970: time), token: ChangeToken(rawValue: seq)
                )
            }
        }
    }

    /// Removes the log entries of deleted records from before `token`. Entries for existing records stay,
    /// because there is only one per record. A sync layer calls this once the server has the deletes.
    public func pruneChanges(before token: ChangeToken) throws {
        try transaction {
            _ = try db.run("DELETE FROM \"_records_changes\" WHERE kind = 'delete' AND seq < ?", [.integer(token.rawValue)])
        }
    }

    /// A record's version, last change and tag, or `nil` if it isn't stored.
    public func metadata<R: Record>(_ type: R.Type, id: R.ID) throws -> RecordMetadata? {
        try locked {
            guard tableExists(R.table), columns[R.table, default: []].contains("_version") else {
                return try fetch(type, id: id) == nil ? nil : RecordMetadata(version: 0, modified: nil, tag: nil)
            }
            guard let row = try db.run(
                "SELECT \"_version\", \"_modified\", \"_tag\" FROM \(quoted(R.table)) WHERE id = ?", [try ValueCoding.encode(id)]
            ).first else { return nil }
            var version = 0
            if case .integer(let stored) = row["_version"] { version = Int(stored) }
            var modified: Date?
            if case .real(let time) = row["_modified"] { modified = Date(timeIntervalSince1970: time) }
            var tag: Data?
            if case .blob(let data) = row["_tag"] { tag = data }
            return RecordMetadata(version: version, modified: modified, tag: tag)
        }
    }

    /// Stores opaque sync data with a record without changing its version or logging a change.
    public func setTag<R: Record>(_ tag: Data?, for type: R.Type, id: R.ID) throws {
        try transaction {
            guard tableExists(R.table) else { return }
            try ensureTable(R.table)
            _ = try db.run(
                "UPDATE \(quoted(R.table)) SET \"_tag\" = ? WHERE id = ?", [tag.map { .blob($0) } ?? .null, try ValueCoding.encode(id)]
            )
        }
    }
}

// MARK: Sync support

extension RecordContainer {
    /// Runs `body` in one transaction for writes that come from a sync server. They don't change a
    /// record's version or add to the change log, so they're never sent back, and deleting a record
    /// this way also drops its log entry. Contexts still refresh their views afterwards.
    package func applyingSyncedChanges<T>(_ body: () throws -> T) throws -> T {
        try transaction {
            applyingSynced += 1
            defer { applyingSynced -= 1 }
            return try body()
        }
    }

    /// A value the sync layer stores, such as a sync engine's saved state or its change token. Write
    /// related values inside one `transaction` so they can't get out of step.
    package func syncValue(forKey key: String) throws -> Data? {
        try locked {
            guard case .blob(let data) = try db.run(
                "SELECT value FROM \"_records_sync_state\" WHERE key = ?", [.text(key)]
            ).first?["value"] else { return nil }
            return data
        }
    }

    package func setSyncValue(_ value: Data?, forKey key: String) throws {
        try transaction {
            if let value {
                _ = try db.run("INSERT OR REPLACE INTO \"_records_sync_state\" (key, value) VALUES (?, ?)", [.text(key), .blob(value)])
            } else {
                _ = try db.run("DELETE FROM \"_records_sync_state\" WHERE key = ?", [.text(key)])
            }
        }
    }

    /// Counts committed transactions that changed data, so a context can tell its own saves from others.
    var commitCount: Int { locked { commits } }

    /// Calls `handler` after each committed transaction that changed data, on the thread that committed it.
    func observeCommits(_ handler: @escaping @Sendable () -> Void) -> UUID {
        locked {
            let token = UUID()
            commitObservers[token] = handler
            return token
        }
    }

    func removeCommitObserver(_ token: UUID) {
        locked { _ = commitObservers.removeValue(forKey: token) }
    }
}
