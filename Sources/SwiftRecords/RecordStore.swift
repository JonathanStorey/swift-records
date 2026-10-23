import Foundation

/// The engine behind every `RecordContainer` opened on one file: its SQLite connection, the lock that
/// serializes access to it, and what it has cached about the schema. Containers on the same file share one
/// store, so they never disagree about the schema and every context hears about every commit.
///
/// Each record type gets its own table. Each relationship property gets a join table named
/// `Owner.property` that keeps the owner's order. A child's `@Reference(to:)` is a column on the child's
/// table, kept in step with its parent's join table.
final class RecordStore: @unchecked Sendable {
    let db: SQLiteDatabase
    private let lock = NSRecursiveLock()
    private(set) var columns: [String: Set<String>] = [:]
    private var relationInfo: [RelationInfo]?
    private var decoding: Set<RowKey> = []
    /// Asset files written and released by each open transaction, innermost last.
    private var fileChanges: [(created: [URL], released: [String])] = []
    /// Records logged by each open transaction, innermost last, so a record's version goes up once per save.
    private var logged: [[RowKey: RecordChange.Kind]] = []
    /// Above zero while applying changes from a sync server, which are never logged.
    private(set) var applyingSynced = 0
    /// True once the open transaction has written something a fetch could see.
    var changedData = false
    /// Goes up with each committed transaction that changed data.
    private var commits = 0
    private var commitObservers: [UUID: @Sendable () -> Void] = [:]
    /// Record types whose renames and indexes have been applied.
    private var prepared: Set<ObjectIdentifier> = []
    /// Each table's `@Timestamp(.created)` and `@Timestamp(.modified)` columns, which a local change stamps.
    private var stampColumns: [String: (created: [String], modified: [String])] = [:]
    /// Goes up whenever links change, a row is deleted or an asset file is written: anything a cached copy
    /// of the edited records could not already show.
    private var structuralChanges = 0
    /// How deeply the current thread holds the lock, so other processes' changes are checked once per access.
    private var lockDepth = 0
    /// SQLite's count of commits by other connections, such as an app extension's, as last seen.
    private var dataVersion: Int64?
    /// Record types registered with a container, by table, so a server's records can be stored before
    /// code uses their type.
    var registered: [String: any Record.Type] = [:]
    /// True when a container with a sync provider is open on this file, which turns on snapshots and
    /// keeps links whose targets haven't arrived.
    var syncEnabled = false
    /// Children whose `.deleteSelf` reference was cleared by the open transaction. Any still without a
    /// parent when it ends are deleted, since a `.deleteSelf` child can't outlive its parent.
    private var orphans: [(table: String, id: SQLiteValue, column: String)] = []

    var structureVersion: Int { locked { structuralChanges } }

    struct RelationInfo: Equatable {
        let ownerTable: String
        let field: String
        let targetTable: String
        /// The target's `@Reference(to:)` column that points back at the owner, or `nil` for a relationship
        /// the target doesn't declare a parent for.
        var childField: String?
        /// What happens to a child when its owner is deleted or drops it.
        var action: ReferenceAction = .none
        var table: String { ownerTable + "." + field }
    }

    /// The database file, or `nil` for an in-memory store.
    let url: URL?

    /// Where asset files are stored: beside the database file and named after it, such as
    /// `_default.assets`. An in-memory store uses a temporary folder that is removed with it.
    let assetsDirectory: URL

    private struct OpenStore {
        weak var store: RecordStore?
    }

    private nonisolated(unsafe) static var openStores: [String: OpenStore] = [:]
    private static let openStoresLock = NSLock()

    /// The store for a file: the one already open, or a new one. Every in-memory store is new.
    static func open(url: URL?) throws -> RecordStore {
        do {
            return try openStore(url: url)
        } catch {
            throw RecordsError.mapping(error)
        }
    }

    private static func openStore(url: URL?) throws -> RecordStore {
        guard let url else { return try RecordStore(url: nil) }
        let key = fileKey(url)
        openStoresLock.lock()
        defer { openStoresLock.unlock() }
        if let store = openStores[key]?.store {
            return store
        }
        let store = try RecordStore(url: url)
        openStores[key] = OpenStore(store: store)
        return store
    }

    /// One spelling per file, so `/var/…` and `/private/var/…` find the same store.
    static func fileKey(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    private init(url: URL?) throws {
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
            CREATE TABLE IF NOT EXISTS "_records_sync" (
                record_table TEXT NOT NULL, record_id NOT NULL, acked INTEGER NOT NULL DEFAULT 0,
                known INTEGER NOT NULL DEFAULT 0, tag BLOB, snapshot BLOB, extra BLOB, synced_at REAL,
                PRIMARY KEY (record_table, record_id));
            CREATE TABLE IF NOT EXISTS "_records_parked" (
                record_table TEXT NOT NULL, record_id NOT NULL, record BLOB NOT NULL,
                PRIMARY KEY (record_table, record_id));
            CREATE TABLE IF NOT EXISTS "_records_uploaded_assets" (name TEXT PRIMARY KEY);
            """)
        // Files from before child references.
        if try !db.run("PRAGMA table_info(\"_records_relations\")").contains(where: { $0["name"] == .text("child_field") }) {
            try db.execute("ALTER TABLE \"_records_relations\" ADD COLUMN child_field TEXT")
        }
        // Files from before synced timestamps.
        if try !db.run("PRAGMA table_info(\"_records_sync\")").contains(where: { $0["name"] == .text("synced_at") }) {
            try db.execute("ALTER TABLE \"_records_sync\" ADD COLUMN synced_at REAL")
        }
    }

    deinit {
        if url == nil {
            try? FileManager.default.removeItem(at: assetsDirectory)
        }
    }

    // MARK: Transactions

    /// Runs `body` atomically. Nested calls join the outer transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            fileChanges.append(([], []))
            logged.append([:])
            do {
                let result = try db.transaction {
                    let result = try body()
                    if fileChanges.count == 1 {
                        try deleteOrphans()
                    }
                    return result
                }
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
                    orphans = []
                }
                // Files written by the rolled-back work go with it, and released ones stay.
                for url in fileChanges.removeLast().created {
                    try? FileManager.default.removeItem(at: url)
                }
                // DDL rolls back with the transaction, so forget anything we cached about the schema.
                columns = [:]
                relationInfo = nil
                prepared = []
                throw error
            }
        }
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        lockDepth += 1
        defer {
            lockDepth -= 1
            lock.unlock()
        }
        if lockDepth == 1 {
            noticeExternalChanges()
        }
        do {
            return try body()
        } catch {
            throw lockDepth == 1 ? RecordsError.mapping(error) : error
        }
    }

    /// Picks up commits another process made to the file, such as a widget's. Its schema may differ from
    /// what this store cached, and every context must refresh, as after a commit of its own.
    private func noticeExternalChanges() {
        guard url != nil, case .integer(let version)? = (try? db.run("PRAGMA data_version"))?.first?["data_version"] else {
            return
        }
        defer { dataVersion = version }
        guard let dataVersion, dataVersion != version else { return }
        columns = [:]
        relationInfo = nil
        prepared = []
        structuralChanges += 1
        commits += 1
        commitObservers.values.forEach { $0() }
    }

    /// Checks for changes other processes made to the file. Every access to the store also does this.
    func checkForExternalChanges() {
        locked {}
    }

    // MARK: Saving

    /// Inserts or updates a record, every record nested inside it, and its relationships.
    func save<R: Record>(_ record: R) throws {
        try save([record])
    }

    func save<R: Record>(_ records: [R]) throws {
        try transaction {
            var visited: Set<RowKey> = []
            for record in records {
                try saveRecord(record, visited: &visited)
            }
        }
    }

    /// Saves one record. `parent` sets a child's reference, for a child saved through its parent's array.
    private func saveRecord<R: Record>(
        _ record: R, visited: inout Set<RowKey>, parent: (column: String, id: SQLiteValue)? = nil
    ) throws {
        let id = try record.sqlID
        guard visited.insert(RowKey(table: R.table, id: id)).inserted else { return }
        var encoded = try RecordEncoder.encode(record)
        encoded.columns += try storeAssets(of: R.self, id: id, assets: encoded.assets)
        // Timestamps are the container's to set, so a save keeps the stored ones.
        var preserving = Set(R.schema.fields.filter { $0.timestamp != nil }.map(\.name))
        if let parent {
            encoded.columns.removeAll { $0.name == parent.column }
            encoded.columns.append((parent.column, parent.id))
            // A copy saved through one parent may not know its other parents, so it never clears them.
            for field in R.schema.fields where field.parent != nil && field.name != parent.column {
                if !encoded.columns.contains(where: { $0.name == field.name && $0.value != .null }) {
                    encoded.columns.removeAll { $0.name == field.name }
                    preserving.insert(field.name)
                }
            }
        }

        try ensureTable(R.table)
        try prepare(R.self)
        try ensureColumns(encoded.columns.map(\.name), in: R.table)
        let references = try referenceValues(R.self, id: id)
        try upsert(encoded.columns, id: id, into: R.table, preserving: preserving)
        try reconcileReferences(R.self, id: id, before: references)

        var linked: Set<String> = []
        for relation in encoded.relations {
            linked.insert(relation.name)
            guard let field = R.schema.field(named: relation.name) else { continue }
            let info = try ensureRelation(R.self, field: field, target: relation.targetType)
            for target in relation.targets {
                try saveRecord(target, visited: &visited, parent: info.childField.map { ($0, id) })
            }
            try link(info, ownerID: id, targets: relation.targets.map { try $0.sqlID })
        }
        // Relations the encoder skipped, such as an optional that is now nil, are unlinked.
        for info in relations() where info.ownerTable == R.table && !linked.contains(info.field) {
            try link(info, ownerID: id, targets: [])
        }
    }

    // MARK: Assets

    /// Writes new asset files and releases the ones a record no longer holds. Returns the asset columns.
    func storeAssets<R: Record>(of type: R.Type, id: SQLiteValue, assets: [String: Asset]) throws -> [(name: String, value: SQLiteValue)] {
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
            // A fetched asset: copy its file unless it is already here, such as one released earlier in this
            // transaction. A synced record's file may not have downloaded yet, and arrives under its name later.
            if manager.fileExists(atPath: source.path), !(owner == nil && manager.fileExists(atPath: destination.path)) {
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

    func upsert(
        _ values: [(name: String, value: SQLiteValue)], id: SQLiteValue, into table: String, preserving kept: Set<String> = []
    ) throws {
        var row: [String: SQLiteValue] = [:]
        for (name, value) in values where name != "id" {
            row[name] = value
        }
        // Columns missing from the encoding (nil optionals) are cleared.
        for column in columns[table, default: []] where !Self.internalColumns.contains(column) && !kept.contains(column) && row[column] == nil {
            row[column] = .null
        }
        let names = row.keys.sorted()
        // Skip the write when nothing changed, which is the common case when an edited array is saved.
        let existing = try db.run("SELECT \(recordColumns(table)) FROM \(quoted(table)) WHERE id = ?", [id]).first
        if let existing, names.allSatisfy({ existing[$0, default: .null] == row[$0] }) {
            return
        }
        if existing != nil {
            try snapshotBeforeChange(table, id: id)
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

    /// Replaces an owner's links. Locally the owner's array decides, and its children's references follow
    /// it. From a server each child's reference decides, and the owner's list only orders the children.
    func link(_ info: RelationInfo, ownerID: SQLiteValue, targets: [SQLiteValue]) throws {
        let table = quoted(info.table)
        let current = try db.run("SELECT target FROM \(table) WHERE owner = ? ORDER BY position", [ownerID]).map { $0["target"]! }
        var targets = targets
        if let child = info.childField, applyingSynced > 0 {
            // A child that points elsewhere has moved, and one that points here belongs even if the list lacks it.
            targets = try targets.filter { target in
                try referenceValue(info.targetTable, column: child, id: target).map { $0 == ownerID } ?? true
            }
            for target in try children(of: ownerID, in: info) where !targets.contains(target) {
                targets.append(target)
            }
        }
        if syncEnabled, applyingSynced == 0 {
            // Links a server delivered before their targets stay, in place, until the targets arrive.
            for (index, target) in current.enumerated() where !targets.contains(target) {
                if try !rowExists(info.targetTable, id: target) {
                    targets.insert(target, at: min(index, targets.count))
                }
            }
        }
        guard current != targets else { return }
        try snapshotBeforeChange(info.ownerTable, id: ownerID)
        structuralChanges += 1
        // In a synced store the links belong to the owner, so changing them is a change to the owner.
        try logChange(info.ownerTable, id: ownerID)
        try db.run("DELETE FROM \(table) WHERE owner = ?", [ownerID])

        // Inverses are unordered, so `inverse_position` is always 0. The column stays for older files.
        for (position, target) in targets.enumerated() {
            try db.run(
                "INSERT INTO \(table) (owner, target, position, inverse_position) VALUES (?, ?, ?, 0)",
                [ownerID, target, .integer(Int64(position))]
            )
        }

        guard let child = info.childField, applyingSynced == 0 else { return }
        try ensureColumns([child], in: info.targetTable)
        let linked = Set(current)
        for target in targets where !linked.contains(target) {
            guard let previous = try referenceValue(info.targetTable, column: child, id: target), previous != ownerID else { continue }
            // A child linked here leaves its previous parent.
            if previous != .null {
                try unlink(info, ownerID: previous, target: target)
            }
            try setReference(info.targetTable, column: child, id: target, to: ownerID)
        }
        let kept = Set(targets)
        for removed in current where !kept.contains(removed) {
            guard try referenceValue(info.targetTable, column: child, id: removed) == ownerID else { continue }
            try setReference(info.targetTable, column: child, id: removed, to: .null)
            if info.action == .deleteSelf {
                orphans.append((info.targetTable, removed, child))
            }
        }
    }

    // MARK: Child references

    /// The current values of a record's `@Reference(to:)` columns, or `nil` if it isn't stored yet.
    func referenceValues<R: Record>(_ type: R.Type, id: SQLiteValue) throws -> [String: SQLiteValue]? {
        let names = R.schema.fields.filter { $0.parent != nil }.map(\.name)
        guard !names.isEmpty else { return [:] }
        try ensureColumns(names, in: R.table)
        let columns = names.map(quoted).joined(separator: ", ")
        return try db.run("SELECT \(columns) FROM \(quoted(R.table)) WHERE id = ?", [id]).first
    }

    /// Moves a record in its parents' join tables after its `@Reference(to:)` columns change: out of the
    /// old parent's array and onto the end of the new one's. A `.deleteSelf` child left without a parent is
    /// deleted when the transaction ends.
    func reconcileReferences<R: Record>(_ type: R.Type, id: SQLiteValue, before: [String: SQLiteValue]?) throws {
        for field in R.schema.fields {
            guard let parent = field.parent, let parentType = Swift.type(of: parent).rootType as? any Record.Type,
                  let parentField = Self.fieldName(of: parentType, for: parent) else { continue }
            let old = before?[field.name] ?? .null
            let new = try referenceValue(R.table, column: field.name, id: id) ?? .null
            guard old != new else { continue }
            let info = try ensureRelation(
                owner: parentType.table, field: parentField, target: R.table, child: (field.name, field.action)
            )
            if old != .null {
                try unlink(info, ownerID: old, target: id)
            }
            if new != .null, tableExists(info.table),
               try db.run("SELECT 1 FROM \(quoted(info.table)) WHERE owner = ? AND target = ?", [new, id]).isEmpty {
                try noteLinkChange(info, ownerID: new)
                try db.run(
                    """
                    INSERT INTO \(quoted(info.table)) (owner, target, position, inverse_position)
                    VALUES (?1, ?2, (SELECT COALESCE(MAX(position), -1) + 1 FROM \(quoted(info.table)) WHERE owner = ?1), 0)
                    """,
                    [new, id]
                )
            }
            if new == .null, field.action == .deleteSelf, applyingSynced == 0 {
                orphans.append((R.table, id, field.name))
            }
        }
    }

    /// The stored name of the property at `keyPath` on `type`.
    private static func fieldName<T: Record>(of type: T.Type, for keyPath: AnyKeyPath) -> String? {
        T.fieldName(for: keyPath)
    }

    /// A child's reference column, `.null` when it has no parent, or `nil` when the child isn't stored.
    private func referenceValue(_ table: String, column: String, id: SQLiteValue) throws -> SQLiteValue? {
        guard tableExists(table) else { return nil }
        guard columns[table, default: []].contains(column) else {
            return try rowExists(table, id: id) ? .null : nil
        }
        return try db.run("SELECT \(quoted(column)) FROM \(quoted(table)) WHERE id = ?", [id]).first.map { $0[column] ?? .null }
    }

    /// The records whose reference points at `ownerID` through this relationship, in stored order.
    private func children(of ownerID: SQLiteValue, in info: RelationInfo) throws -> [SQLiteValue] {
        guard let child = info.childField, tableExists(info.targetTable), columns[info.targetTable, default: []].contains(child) else {
            return []
        }
        return try db.run(
            "SELECT id FROM \(quoted(info.targetTable)) WHERE \(quoted(child)) = ? ORDER BY \"_position\", id", [ownerID]
        ).map { $0["id"]! }
    }

    /// Sets a child's reference column, which is a change to the child.
    private func setReference(_ table: String, column: String, id: SQLiteValue, to value: SQLiteValue) throws {
        try snapshotBeforeChange(table, id: id)
        structuralChanges += 1
        try db.run("UPDATE \(quoted(table)) SET \(quoted(column)) = ? WHERE id = ?", [value, id])
        try logChange(table, id: id)
    }

    /// Removes one target from an owner's links, which is a change to the owner.
    private func unlink(_ info: RelationInfo, ownerID: SQLiteValue, target: SQLiteValue) throws {
        guard tableExists(info.table),
              try !db.run("SELECT 1 FROM \(quoted(info.table)) WHERE owner = ? AND target = ?", [ownerID, target]).isEmpty else { return }
        try noteLinkChange(info, ownerID: ownerID)
        try db.run("DELETE FROM \(quoted(info.table)) WHERE owner = ? AND target = ?", [ownerID, target])
    }

    /// Records that an owner's links are about to change, if the owner is stored.
    private func noteLinkChange(_ info: RelationInfo, ownerID: SQLiteValue) throws {
        structuralChanges += 1
        guard try rowExists(info.ownerTable, id: ownerID) else { return }
        try snapshotBeforeChange(info.ownerTable, id: ownerID)
        try logChange(info.ownerTable, id: ownerID)
    }

    /// Deletes the `.deleteSelf` children the transaction left without a parent.
    private func deleteOrphans() throws {
        while !orphans.isEmpty {
            let orphan = orphans.removeFirst()
            if try referenceValue(orphan.table, column: orphan.column, id: orphan.id) == .null {
                try deleteRow(orphan.table, id: orphan.id)
            }
        }
    }

    /// Stores the order of some or all records of one type. The records take the places they already
    /// hold among themselves, so ordering a filtered subset leaves every other record where it was.
    func setOrder<R: Record>(_ ids: [R.ID], for type: R.Type) throws {
        try transaction {
            guard tableExists(R.table) else { return }
            var rows = try db.run("SELECT id, \"_position\" FROM \(quoted(R.table)) ORDER BY \"_position\", id")
            // Ties or gaps from older versions would make shared places ambiguous, so number the table first.
            let positions = rows.map { $0["_position"] ?? .null }
            if Set(positions).count != positions.count || positions.contains(.null) {
                for (position, row) in rows.enumerated() {
                    try db.run("UPDATE \(quoted(R.table)) SET \"_position\" = ? WHERE id = ?", [.integer(Int64(position)), row["id"]!])
                }
                rows = try db.run("SELECT id, \"_position\" FROM \(quoted(R.table)) ORDER BY \"_position\", id")
            }
            var current: [SQLiteValue: SQLiteValue] = [:]
            for row in rows {
                current[row["id"]!] = row["_position"]!
            }
            var seen: Set<SQLiteValue> = []
            let ordered = try ids.map { try ValueCoding.encode($0) }.filter { current[$0] != nil && seen.insert($0).inserted }
            let slots = ordered.map { current[$0]! }.sorted { $0.integerValue < $1.integerValue }
            for (id, position) in zip(ordered, slots) where current[id] != position {
                try setPosition(position, table: R.table, id: id)
            }
        }
    }

    /// Moves a record to a place in its type's stored order, which is a change to the record.
    func setPosition(_ position: SQLiteValue, table: String, id: SQLiteValue) throws {
        guard try db.run("SELECT \"_position\" FROM \(quoted(table)) WHERE id = ?", [id]).first?["_position"] != position else { return }
        // Not structural: a view that moved the record already shows it there.
        try snapshotBeforeChange(table, id: id)
        try db.run("UPDATE \(quoted(table)) SET \"_position\" = ? WHERE id = ?", [position, id])
        try logChange(table, id: id)
    }

    // MARK: Deleting

    /// Deletes a record and applies each relationship's delete rule.
    func delete<R: Record>(_ record: R) throws {
        try delete(R.self, id: record.id)
    }

    func delete<R: Record>(_ type: R.Type, id: R.ID) throws {
        let id = try ValueCoding.encode(id)
        try transaction { try deleteRow(R.table, id: id) }
    }

    /// Deletes every record that matches the predicate, or every record of the type without one.
    func delete<R: Record>(_ type: R.Type, where predicate: Predicate<R>?) throws {
        try transaction {
            guard tableExists(R.table) else { return }
            try prepare(R.self)
            let ids: [SQLiteValue]
            if let (clause, bindings) = try whereClause(predicate) {
                ids = try db.run("SELECT id FROM \(quoted(R.table))\(clause)", bindings).map { $0["id"]! }
            } else {
                ids = try fetchRecords(R.self, where: predicate, page: nil).map { try $0.sqlID }
            }
            for id in ids {
                try deleteRow(R.table, id: id)
            }
        }
    }

    /// Removes every record, link and asset file, and empties the change log and sync state. Tokens keep
    /// counting up from where they were, so an old token never matches new changes.
    func deleteAllData() throws {
        try locked {
            try transaction {
                let tables = try db.run("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
                    .compactMap { row -> String? in
                        if case .text(let name) = row["name"] { return name }
                        return nil
                    }
                for table in tables {
                    try db.execute(table.hasPrefix("_records_") ? "DELETE FROM \(quoted(table))" : "DROP TABLE \(quoted(table))")
                }
                changedData = true
                structuralChanges += 1
            }
            columns = [:]
            relationInfo = nil
            prepared = []
            try? FileManager.default.removeItem(at: assetsDirectory)
            // Registered types get their tables back, ready for records from a server.
            let types = Array(registered.values)
            registered = [:]
            try register(types)
        }
    }

    /// Deletes by table name, so cascades work for types this process has never loaded.
    func deleteRow(_ table: String, id: SQLiteValue) throws {
        guard tableExists(table) else { return }
        try snapshotBeforeChange(table, id: id)
        try keepTagOfDeletedRow(table, id: id)
        structuralChanges += 1
        let owned = relations().filter { $0.ownerTable == table }

        for info in owned {
            try db.run("DELETE FROM \(quoted(info.table)) WHERE owner = ?", [id])
            // Children go with their parent or lose their reference to it, by their action.
            for child in try children(of: id, in: info) {
                if info.action == .deleteSelf {
                    try deleteRow(info.targetTable, id: child)
                } else {
                    try setReference(info.targetTable, column: info.childField!, id: child, to: .null)
                }
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

    func rowExists(_ table: String, id: SQLiteValue) throws -> Bool {
        guard tableExists(table) else { return false }
        return try !db.run("SELECT 1 FROM \(quoted(table)) WHERE id = ?", [id]).isEmpty
    }

    // MARK: Fetching

    func fetch<R: Record>(_ type: R.Type, id: R.ID) throws -> R? {
        try fetch(type, ids: [id]).first
    }

    /// Fetches records by ID in the order given, skipping any that no longer exist.
    func fetch<R: Record>(_ type: R.Type, ids: [R.ID]) throws -> [R] {
        try fetch(type, ids: ids, storedOrder: false)
    }

    /// Fetches records by ID in their stored order, skipping any that no longer exist. Use it to load an
    /// inverse relationship: `container.fetch(Cookbook.self, ids: recipe.cookbookIDs)`.
    func fetch<R: Record>(_ type: R.Type, ids: Set<UUID>) throws -> [R] {
        try fetch(type, ids: Array(ids), storedOrder: true)
    }

    private func fetch<R: Record>(_ type: R.Type, ids: [R.ID], storedOrder: Bool) throws -> [R] {
        try locked {
            guard tableExists(R.table) else { return [] }
            try prepare(R.self)
            let ids = try ids.map { try ValueCoding.encode($0) }
            var rows: [SQLiteValue: [String: SQLiteValue]] = [:]
            for chunk in ids.chunked(into: Self.batchSize) {
                for row in try db.run("SELECT \(recordColumns(R.table)) FROM \(quoted(R.table)) WHERE id IN (\(placeholders(chunk.count)))", Array(chunk)) {
                    rows[row["id"]!] = row
                }
            }
            var found = ids.compactMap { rows[$0] }
            if storedOrder {
                var places: [SQLiteValue: Int64] = [:]
                for chunk in ids.chunked(into: Self.batchSize) {
                    for row in try db.run("SELECT id, \"_position\" FROM \(quoted(R.table)) WHERE id IN (\(placeholders(chunk.count)))", Array(chunk)) {
                        if case .integer(let place)? = row["_position"] { places[row["id"]!] = place }
                    }
                }
                found.sort { places[$0["id"]!, default: .max] < places[$1["id"]!, default: .max] }
            }
            return try prefetching(R.table, rows: found) {
                try found.map { try decodeRow(R.self, row: $0) }
            }
        }
    }

    /// Fetches records matching a predicate in their stored order.
    ///
    /// Simple predicates on a record's own properties run as SQL. Anything else is evaluated in memory.
    func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil) throws -> [R] {
        try locked { try fetchRecords(R.self, where: predicate, page: nil) }
    }

    /// Fetches one page of records: at most `limit` of them, starting `offset` records into the results.
    ///
    /// The slice's indices are the records' positions in the full results, so a page fetched with an
    /// offset of 40 starts at index 40. The page is read straight from SQL when the predicate translates.
    func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        limit: Int,
        offset: Int = 0
    ) throws -> RecordSlice<R> {
        precondition(limit >= 0 && offset >= 0, "limit and offset must not be negative")
        return try locked {
            RecordSlice(try fetchRecords(R.self, where: predicate, page: (limit, offset)), startIndex: offset)
        }
    }

    func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try locked {
            guard tableExists(R.table) else { return 0 }
            try prepare(R.self)
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
        // A synced timestamp isn't a column, so a predicate on it runs in memory.
        let synced = Set(R.schema.fields.filter { $0.timestamp == .synced }.map(\.name))
        if clause.columns.contains(where: { $0.table == R.table && synced.contains($0.column) }) {
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
        try prepare(R.self)
        let translated = try whereClause(predicate)
        var sql = "SELECT \(recordColumns(R.table)) FROM \(quoted(R.table))" + (translated?.0 ?? "") + " ORDER BY \"_position\", id"
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
        try prepare(R.self)
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
        /// Each target's owners, by join table.
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
                            "SELECT owner, target FROM \(quoted(info.table)) WHERE target IN (\(placeholders(chunk.count)))",
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
        guard decoding.insert(key).inserted else { throw RecordsError.cycle(type: R.table) }
        defer { decoding.remove(key) }
        do {
            return try R(from: RecordDecoder<R>(row: row, loader: self))
        } catch is DecodingError {
            throw RecordsError.incompatibleRecord(type: R.table, id: (try? ValueCoding.decode(UUID.self, from: key.id)) ?? UUID())
        }
    }

    // MARK: Schema

    func tableExists(_ table: String) -> Bool {
        if columns[table] != nil { return true }
        let rows = (try? db.run("PRAGMA table_info(\(quoted(table)))")) ?? []
        guard !rows.isEmpty else { return false }
        columns[table] = Set(rows.compactMap { row -> String? in
            if case .text(let name) = row["name"] { return name }
            return nil
        })
        return true
    }

    func ensureTable(_ table: String) throws {
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

    /// Applies `@Renamed` and `@Indexed` to a table the first time this container uses its type: old
    /// columns, join tables and asset entries take the new name, and indexed columns get an index.
    func prepare<R: Record>(_ type: R.Type) throws {
        guard !prepared.contains(ObjectIdentifier(R.self)), tableExists(R.table) else { return }
        for field in R.schema.fields {
            for old in field.previousNames {
                try rename(field: old, to: field.name, in: R.table)
            }
            if field.timestamp == .created || field.timestamp == .modified {
                try ensureColumns([field.name], in: R.table)
            }
            if field.isIndexed {
                try ensureColumns([field.name], in: R.table)
                try db.execute(
                    "CREATE INDEX IF NOT EXISTS \(quoted(R.table + "." + field.name + ".index")) ON \(quoted(R.table)) (\(quoted(field.name)))"
                )
            }
        }
        stampColumns[R.table] = (
            R.schema.fields.filter { $0.timestamp == .created }.map(\.name), R.schema.fields.filter { $0.timestamp == .modified }.map(\.name)
        )
        prepared.insert(ObjectIdentifier(R.self))
    }

    private func rename(field old: String, to new: String, in table: String) throws {
        let existing = columns[table, default: []]
        if existing.contains(old), !existing.contains(new) {
            try db.execute("ALTER TABLE \(quoted(table)) RENAME COLUMN \(quoted(old)) TO \(quoted(new))")
            columns[table]?.remove(old)
            columns[table]?.insert(new)
        }
        let relations = relations()
        if relations.contains(where: { $0.ownerTable == table && $0.field == old }),
           !relations.contains(where: { $0.ownerTable == table && $0.field == new }) {
            try db.execute("ALTER TABLE \(quoted(table + "." + old)) RENAME TO \(quoted(table + "." + new))")
            try db.run("UPDATE \"_records_relations\" SET field = ? WHERE owner_table = ? AND field = ?", [.text(new), .text(table), .text(old)])
            relationInfo = nil
        }
        try db.run("UPDATE \"_records_assets\" SET field = ? WHERE owner_table = ? AND field = ?", [.text(new), .text(table), .text(old)])
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
    func ensureColumns(_ names: [String], in table: String) throws {
        try ensureTable(table)
        for name in names where !columns[table, default: []].contains(name) {
            try db.execute("ALTER TABLE \(quoted(table)) ADD COLUMN \(quoted(name))")
            columns[table, default: []].insert(name)
        }
    }

    func relations() -> [RelationInfo] {
        if let relationInfo { return relationInfo }
        let rows = (try? db.run("SELECT * FROM \"_records_relations\"")) ?? []
        let loaded = rows.compactMap { row -> RelationInfo? in
            guard case .text(let owner) = row["owner_table"], case .text(let field) = row["field"],
                  case .text(let target) = row["target_table"], case .text(let action) = row["delete_rule"] else { return nil }
            var child: String?
            if case .text(let name) = row["child_field"] { child = name }
            // Actions from before child references, such as `cascade`, read as `.none`.
            return RelationInfo(
                ownerTable: owner, field: field, targetTable: target, childField: child,
                action: child == nil ? .none : ReferenceAction(rawValue: action) ?? .none
            )
        }
        relationInfo = loaded
        return loaded
    }

    /// The relationship behind an owner's forward property, with the child reference its target declares for it.
    func ensureRelation<R: Record>(_ type: R.Type, field: RecordSchema<R>.Field, target: any Record.Type) throws -> RelationInfo {
        try ensureRelation(owner: R.table, field: field.name, target: target.table, child: Self.childReference(in: target, to: field.keyPath))
    }

    /// The `@Reference(to:)` property of `target` that points at `parent`, such as `Note.todo` for `\ToDo.notes`.
    static func childReference(in target: any Record.Type, to parent: AnyKeyPath) -> (name: String, action: ReferenceAction)? {
        func find<T: Record>(_ type: T.Type) -> (name: String, action: ReferenceAction)? {
            T.schema.fields.first { $0.parent == parent }.map { ($0.name, $0.action) }
        }
        return find(target)
    }

    func ensureRelation(owner: String, field: String, target: String, child: (name: String, action: ReferenceAction)?) throws -> RelationInfo {
        let info = RelationInfo(ownerTable: owner, field: field, targetTable: target, childField: child?.name, action: child?.action ?? .none)
        if relations().contains(info) { return info }
        try db.run(
            """
            INSERT OR REPLACE INTO "_records_relations" (owner_table, field, target_table, delete_rule, child_field)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.text(owner), .text(field), .text(target), .text(info.action.rawValue), child.map { .text($0.name) } ?? .null]
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
            throw RecordsError.unknownInverse("\(keyPath)")
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
            "SELECT owner FROM \(quoted(info.table)) WHERE target = ?", [targetID]
        ).map { $0["owner"]! }
    }

    func hasRelation(owner table: String, field: String) -> Bool {
        relations().contains { $0.ownerTable == table && $0.field == field }
    }

    /// Counts linked records that exist. A link a server delivered before its target doesn't count.
    func relationCount(owner table: String, ownerID: SQLiteValue, field: String) throws -> Int {
        guard let info = relations().first(where: { $0.ownerTable == table && $0.field == field }) else { return 0 }
        if let targets = prefetched?.links[info.table]?[ownerID] {
            return targets.filter { prefetched?.rows[info.targetTable]?[$0] != nil }.count
        }
        guard tableExists(info.targetTable) else { return 0 }
        let rows = try db.run(
            "SELECT COUNT(*) AS n FROM \(quoted(info.table)) j JOIN \(quoted(info.targetTable)) t ON t.id = j.target WHERE j.owner = ?",
            [ownerID]
        )
        return Int(rows.first?["n"]?.integerValue ?? 0)
    }

    func assetURL(named name: String) -> URL {
        assetsDirectory.appendingPathComponent(name)
    }

    /// When the server acknowledged the record as it is now, or `nil` while it has unsent changes or has
    /// never synced.
    func syncedDate(table: String, id: SQLiteValue) throws -> Date? {
        let row = try db.run("""
            SELECT s.synced_at, s.acked, c.version FROM "_records_sync" s
            LEFT JOIN "_records_changes" c ON c.record_table = s.record_table AND c.record_id = s.record_id
            WHERE s.record_table = ? AND s.record_id = ? AND s.known = 1
            """, [.text(table), id]).first
        guard let row, case .real(let time) = row["synced_at"],
              (row["version"]?.integerValue ?? 0) <= (row["acked"]?.integerValue ?? 0) else { return nil }
        return Date(timeIntervalSince1970: time)
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

extension RecordStore {
    /// Bumps a record's version and moves its log entry to the end, once per transaction.
    func logChange(_ table: String, id: SQLiteValue, kind: RecordChange.Kind = .save) throws {
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
            if let stamps = stampColumns[table] {
                let sets = stamps.created.map { "\(quoted($0)) = COALESCE(\(quoted($0)), ?1)" } + stamps.modified.map { "\(quoted($0)) = ?1" }
                if !sets.isEmpty {
                    try db.run("UPDATE \(quoted(table)) SET \(sets.joined(separator: ", ")) WHERE id = ?2", [now, id])
                }
            }
        }
        // Replacing the entry gives it a new sequence number at the end of the log.
        try db.run(
            "INSERT OR REPLACE INTO \"_records_changes\" (record_table, record_id, kind, version, time) VALUES (?, ?, ?, ?, ?)",
            [.text(table), id, .text(kind.rawValue), version, now]
        )
    }

    /// The token of the latest change, to store before you start reading changes.
    var changeToken: ChangeToken {
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
    func changes(since token: ChangeToken = .initial) throws -> [RecordChange] {
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

    /// A record's version, last change and tag, or `nil` if it isn't stored.
    func metadata<R: Record>(_ type: R.Type, id: R.ID) throws -> RecordMetadata? {
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
    func setTag<R: Record>(_ tag: Data?, for type: R.Type, id: R.ID) throws {
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

extension RecordStore {
    /// Runs `body` in one transaction for writes that come from a sync server. They don't change a
    /// record's version or add to the change log, so they're never sent back, and deleting a record
    /// this way also drops its log entry. Contexts still refresh their views afterwards.
    func applyingSyncedChanges<T>(_ body: () throws -> T) throws -> T {
        try transaction {
            applyingSynced += 1
            defer { applyingSynced -= 1 }
            return try body()
        }
    }

    /// A value the sync layer stores, such as a sync engine's saved state or its change token. Write
    /// related values inside one `transaction` so they can't get out of step.
    func syncValue(forKey key: String) throws -> Data? {
        try locked {
            guard case .blob(let data) = try db.run(
                "SELECT value FROM \"_records_sync_state\" WHERE key = ?", [.text(key)]
            ).first?["value"] else { return nil }
            return data
        }
    }

    func setSyncValue(_ value: Data?, forKey key: String) throws {
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
