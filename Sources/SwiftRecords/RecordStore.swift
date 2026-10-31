import Foundation

/// The engine behind every `RecordContainer` opened on one file: its SQLite connection, the lock that
/// serializes access to it, and what it has cached about the schema. Containers on the same file share one
/// store, so they never disagree about the schema and every context hears about every commit.
///
/// Each record type gets its own table, holding only its own values. A `@Reference(from:)` pointer is a
/// column, and the `@Reference(to:)` arrays it fills are queries on that column. Each pair in a many-to-many
/// relationship is a `_RecordLink` record. Nothing is stored twice, so there is nothing to keep in step.
final class RecordStore: @unchecked Sendable {
    let db: SQLiteDatabase
    private let lock = NSRecursiveLock()
    private(set) var columns: [String: Set<String>] = [:] {
        didSet { columnLists = [:] }
    }
    /// Each table's `recordColumns`, built once rather than for every row a save compares.
    private var columnLists: [String: String] = [:]
    private var pointerInfo: [PointerInfo]?
    private var decoding: Set<RowKey> = []
    /// Asset files written and released by each open transaction, innermost last.
    private var fileChanges: [(created: [URL], released: [String])] = []
    /// Records logged by each open transaction, innermost last, so a record's version goes up once per save.
    private var logged: [[RowKey: RecordChange.Kind]] = []
    /// Above zero while applying changes from a sync server, which are never logged.
    private(set) var applyingSynced = 0
    /// Above zero while a delete follows pointers to the records that go with it.
    private var cascading = 0
    /// True once the open transaction has written something a fetch could see.
    var changedData = false
    /// Goes up with each committed transaction that changed data.
    private var commits = 0
    private var commitObservers: [UUID: @Sendable () -> Void] = [:]
    /// Rows each open transaction wrote, innermost last, including ones a sync applied unlogged.
    private var touched: [Set<RowKey>] = []
    /// `structuralChanges` when the outermost open transaction began.
    private var structureAtStart = 0
    /// The rows each recent commit wrote, oldest first, or `nil` for one that did more than write rows,
    /// such as a delete, a moved pointer or another process's commit.
    private var recentCommits: [(commit: Int, rows: Set<RowKey>?)] = []
    /// Record types whose renames and indexes have been applied.
    private var prepared: Set<ObjectIdentifier> = []
    /// Each table's `@Timestamped(.created)` and `@Timestamped(.modified)` columns, which a local change stamps.
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
    /// Records whose `.deleteSelf` pointer the open transaction cleared. Any still without a parent when it
    /// ends are deleted, since a `.deleteSelf` record can't outlive its parent.
    private var orphans: [(table: String, id: SQLiteValue, column: String)] = []
    /// What the open journaled transaction has changed, for undo, or `nil` when nothing is journaling.
    var journal: Journal?
    /// Asset files a journaled transaction released, kept here rather than removed so undo can restore them.
    lazy var releasedAssetsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-records-undo-\(UUID().uuidString)", isDirectory: true)

    var structureVersion: Int { locked { structuralChanges } }

    /// The first record of each type that no longer decodes, such as after a property changed type. Fetches
    /// skip it rather than fail, so one bad row doesn't hide the rest.
    private var undecodable: [String: RecordsError] = [:]
    /// Hears the first stored record that doesn't decode, or `nil` once every type's records decode again.
    var undecodableChanged: (@Sendable (RecordsError?) -> Void)?

    /// A `@Reference(from:)` column, kept in `_records_pointers` so deleting a record reaches the records
    /// that point to it, even of types this process hasn't loaded.
    struct PointerInfo: Equatable {
        let table: String
        let field: String
        /// The table it points into, or `nil` for a pointer that can name any record, such as a link's ends.
        let target: String?
        let action: ReferenceAction
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
            CREATE TABLE IF NOT EXISTS "_records_pointers" (
                record_table TEXT NOT NULL, field TEXT NOT NULL, target_table TEXT, action TEXT NOT NULL,
                PRIMARY KEY (record_table, field));
            CREATE TABLE IF NOT EXISTS "_records_assets" (
                name TEXT PRIMARY KEY, owner_table TEXT NOT NULL, owner_id NOT NULL, field TEXT NOT NULL,
                uploaded INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS "_records_assets.owner" ON "_records_assets" (owner_table, owner_id);
            CREATE TABLE IF NOT EXISTS "_records_sync_state" (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS "_records_meta" (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, record_table TEXT NOT NULL, record_id NOT NULL,
                kind TEXT, version INTEGER NOT NULL DEFAULT 0, time REAL,
                acked INTEGER NOT NULL DEFAULT 0, known INTEGER NOT NULL DEFAULT 0, tag BLOB,
                snapshot BLOB, extra BLOB, synced_at REAL, parked BLOB,
                UNIQUE (record_table, record_id));
            -- Only rows with unsent changes, so each sync pass reads those and nothing else.
            CREATE INDEX IF NOT EXISTS "_records_meta.pending" ON "_records_meta" (seq)
                WHERE kind IS NOT NULL AND version > acked;
            """)
    }

    deinit {
        if url == nil {
            try? FileManager.default.removeItem(at: assetsDirectory)
        }
        try? FileManager.default.removeItem(at: releasedAssetsDirectory)
    }

    // MARK: Transactions

    /// Runs `body` atomically. Nested calls join the outer transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            fileChanges.append(([], []))
            logged.append([:])
            touched.append([])
            if fileChanges.count == 1 {
                structureAtStart = structuralChanges
            }
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
                let rows = touched.removeLast()
                if fileChanges.isEmpty {
                    removeReleasedFiles(changes.released)
                    if changedData {
                        changedData = false
                        commits += 1
                        noteCommit(rows: structuralChanges == structureAtStart ? rows : nil)
                        commitObservers.values.forEach { $0() }
                    }
                } else {
                    fileChanges[fileChanges.count - 1].created += changes.created
                    fileChanges[fileChanges.count - 1].released += changes.released
                    logged[logged.count - 1].merge(records) { $1 }
                    touched[touched.count - 1].formUnion(rows)
                }
                return result
            } catch {
                logged.removeLast()
                touched.removeLast()
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
                pointerInfo = nil
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
        pointerInfo = nil
        prepared = []
        structuralChanges += 1
        commits += 1
        noteCommit(rows: nil)
        commitObservers.values.forEach { $0() }
    }

    private func noteCommit(rows: Set<RowKey>?) {
        recentCommits.append((commits, rows))
        if recentCommits.count > 32 {
            recentCommits.removeFirst()
        }
    }

    /// The rows written by the commits after `commit`, or `nil` when one of them did more than write rows
    /// or is too long ago to know.
    func rowsChanged(after commit: Int) -> Set<RowKey>? {
        locked {
            guard commit < commits else { return [] }
            guard let oldest = recentCommits.first, oldest.commit <= commit + 1 else { return nil }
            var rows: Set<RowKey> = []
            for entry in recentCommits where entry.commit > commit {
                guard let written = entry.rows else { return nil }
                rows.formUnion(written)
            }
            return rows
        }
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
        try registerForJournal(R.self)
        try transaction {
            var visited: Set<RowKey> = []
            for record in records {
                try saveRecord(record, visited: &visited)
            }
        }
    }

    /// Saves an edit that started from `base`, the record's stored fields when the edit began. A field
    /// that changed in the store since then, by another save or a sync, keeps that change unless the edit
    /// changed it too, and then the edit wins as the later one. A record deleted since then stays deleted.
    /// Without a base the edit is saved whole.
    func save<R: Record>(_ record: R, base: SyncFields?) throws {
        guard let base else { return try save(record) }
        try registerForJournal(R.self)
        try transaction {
            let id = try record.sqlID
            guard let stored = try localFields(R.self, id: id) else { return }
            var visited: Set<RowKey> = []
            try saveRecord(record, visited: &visited)
            guard stored != base, let ours = try syncFields(R.self, id: id) else { return }
            let merged = mergeFields(R.self, local: ours, server: stored, base: base, localIsLater: true)
            if merged != ours {
                try applySyncFields(R.self, id: record.id, fields: merged)
            }
        }
    }

    /// A stored record's fields, the base an edit starting now merges against, or `nil` if it isn't stored.
    func storedFields<R: Record>(_ type: R.Type, id: R.ID) throws -> SyncFields? {
        try locked { try localFields(R.self, id: try ValueCoding.encode(id)) }
    }

    /// Saves one record and the records its `@Reference(to:)` properties hold. `parent` sets a child's
    /// pointer, for a child saved through its parent's array.
    private func saveRecord<R: Record>(
        _ record: R, visited: inout Set<RowKey>, parent: (column: String, id: SQLiteValue)? = nil
    ) throws {
        let id = try record.sqlID
        guard visited.insert(RowKey(table: R.table, id: id)).inserted else {
            // A child in two arrays of one save ends up in the last.
            if let parent, try db.run("SELECT \(quoted(parent.column)) AS p FROM \(quoted(R.table)) WHERE id = ?", [id]).first?["p"] != parent.id {
                try setReference(R.table, column: parent.column, id: id, to: parent.id)
            }
            return
        }
        var encoded = try RecordEncoder.encode(record)
        encoded.columns += try storeAssets(of: R.self, id: id, assets: encoded.assets)
        // Timestamps are the container's to set, so a save keeps the stored ones.
        var preserving = Set(R.cachedSchema.fields.filter { $0.timestamp != nil }.map { $0.name })
        if let parent {
            encoded.columns.removeAll { $0.name == parent.column }
            encoded.columns.append((parent.column, parent.id))
            // A copy saved through one parent may not know its other parents, so it never clears them.
            for field in R.cachedSchema.fields where field.isPointer && field.name != parent.column {
                if !encoded.columns.contains(where: { $0.name == field.name && $0.value != .null }) {
                    encoded.columns.removeAll { $0.name == field.name }
                    preserving.insert(field.name)
                }
            }
        }

        try writeRow(R.self, id: id, columns: encoded.columns, preserving: preserving)

        let held = Dictionary(encoded.relations.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for field in R.cachedSchema.fields {
            // An optional that is nil isn't encoded, so it holds nothing.
            let targets = held[field.name]?.targets ?? []
            let loaded = held[field.name]?.loaded
            switch field.relationship {
            case .children(let type, let pointer)?:
                try saveChildren(targets, loaded: loaded, ownerID: id, type: type, pointer: pointer, visited: &visited)
            case .links?:
                try saveLinks(targets, loaded: loaded, owner: R.self, ownerID: id, field: field, visited: &visited)
            case nil:
                break
            }
        }
    }

    /// Writes a record's row. A change to a record that points to another changes what that one's
    /// `@Reference(to:)` arrays hold, which a cached copy of it can't show.
    func writeRow<R: Record>(
        _ type: R.Type, id: SQLiteValue, columns: [(name: String, value: SQLiteValue)], preserving: Set<String> = []
    ) throws {
        try ensureTable(R.table)
        try prepare(R.self)
        try ensureColumns(columns.map(\.name), in: R.table)
        if !touched.isEmpty {
            touched[touched.count - 1].insert(RowKey(table: R.table, id: id))
        }
        let pointers = R.cachedSchema.fields.filter { $0.isPointer }.map(\.name)
        let before = pointers.isEmpty ? nil : try db.run(
            "SELECT \(pointers.map(quoted).joined(separator: ", ")) FROM \(quoted(R.table)) WHERE id = ?", [id]
        ).first
        guard try upsert(columns, id: id, into: R.table, preserving: preserving), !pointers.isEmpty else { return }
        let after = try db.run(
            "SELECT \(pointers.map(quoted).joined(separator: ", ")) FROM \(quoted(R.table)) WHERE id = ?", [id]
        ).first ?? [:]
        let moved = pointers.filter { (before?[$0] ?? .null) != (after[$0] ?? .null) }
        guard !moved.isEmpty else { return }
        structuralChanges += 1
        guard before != nil, applyingSynced == 0 else { return }
        for field in R.cachedSchema.fields where field.action == .deleteSelf && moved.contains(field.name) {
            if after[field.name, default: .null] == .null {
                orphans.append((R.table, id, field.name))
            }
        }
    }

    // MARK: Assets

    /// Writes new asset files and releases the ones a record no longer holds. Returns the asset columns.
    func storeAssets<R: Record>(of type: R.Type, id: SQLiteValue, assets: [String: Asset]) throws -> [(name: String, value: SQLiteValue)] {
        let assetFields = R.cachedSchema.fields.filter { $0.isAsset }
        let fields = Set(assetFields.map { $0.name }).union(assets.keys)
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
                keepOrRemoveReleasedFile(named: name)
            }
        }
    }

    /// Inserts or updates a row, and returns whether anything changed.
    @discardableResult
    private func upsert(
        _ values: [(name: String, value: SQLiteValue)], id: SQLiteValue, into table: String, preserving kept: Set<String> = []
    ) throws -> Bool {
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
            return false
        }
        if existing != nil {
            try beforeChange(table, id: id)
        } else {
            try journalBeforeChange(table, id: id)
        }
        let insertColumns = (["id"] + names).map(quoted).joined(separator: ", ")
        let placeholders = (["?"] + names.map { _ in "?" }).joined(separator: ", ")
        let conflict = names.isEmpty
            ? "DO NOTHING"
            : "DO UPDATE SET " + names.map { "\(quoted($0)) = excluded.\(quoted($0))" }.joined(separator: ", ")
        try db.run(
            "INSERT INTO \(quoted(table)) (\(insertColumns)) VALUES (\(placeholders)) ON CONFLICT(\"id\") \(conflict)",
            [id] + names.map { row[$0]! }
        )
        try logChange(table, id: id)
        return true
    }

    // MARK: Relationships

    /// Saves the records a `@Reference(to:)` array holds, each pointing to its owner, and applies the
    /// pointer's action to the records that pointed here and no longer belong. With `loaded`, the IDs the
    /// array held when fetched, only those taken out since then are removed, so a child that arrived
    /// from another device after the fetch stays.
    private func saveChildren(
        _ children: [any Record], loaded: Set<UUID>?, ownerID: SQLiteValue, type: any Record.Type, pointer: AnyKeyPath,
        visited: inout Set<RowKey>
    ) throws {
        func save<C: Record>(_ type: C.Type) throws {
            guard let field = C.cachedSchema.field(for: pointer), field.isPointer else { return }
            var kept: Set<SQLiteValue> = []
            for case let child as C in children {
                kept.insert(try child.sqlID)
                try saveRecord(child, visited: &visited, parent: (field.name, ownerID))
            }
            guard tableExists(C.table) else { return }
            try ensureColumns([field.name], in: C.table)
            for row in try db.run("SELECT id FROM \(quoted(C.table)) WHERE \(quoted(field.name)) = ?", [ownerID]) {
                let id = row["id"]!
                guard !kept.contains(id), try wasRemoved(id, from: loaded) else { continue }
                if field.action == .deleteSelf {
                    try deleteRow(C.table, id: id)
                } else {
                    try setReference(C.table, column: field.name, id: id, to: .null)
                }
            }
        }
        try save(type)
    }

    /// Deletes the `.deleteSelf` records the transaction left without a parent.
    private func deleteOrphans() throws {
        while !orphans.isEmpty {
            let orphan = orphans.removeFirst()
            guard tableExists(orphan.table) else { continue }
            let value = try db.run("SELECT \(quoted(orphan.column)) AS p FROM \(quoted(orphan.table)) WHERE id = ?", [orphan.id]).first
            if let value, value["p"] == .null {
                try deleteRow(orphan.table, id: orphan.id)
            }
        }
    }

    /// Saves the records a many-to-many array holds, and adds and removes link records so exactly those
    /// are linked. Links made in one save are a millisecond apart, so they keep the array's order. With
    /// `loaded`, only links to targets taken out since the fetch are removed.
    private func saveLinks<R: Record>(
        _ targets: [any Record], loaded: Set<UUID>?, owner: R.Type, ownerID: SQLiteValue, field: RecordSchema<R>.Field,
        visited: inout Set<RowKey>
    ) throws {
        func save<T: Record>(_ record: T) throws {
            try saveRecord(record, visited: &visited)
        }
        if registered[_RecordLink.table] == nil {
            try register([])
        }
        var wanted: [SQLiteValue] = []
        for target in targets {
            try save(target)
            let id = try target.sqlID
            if !wanted.contains(id) { wanted.append(id) }
        }
        let names = Self.relationNames(R.self, field: field)
        let links = quoted(_RecordLink.table)
        var linked: Set<SQLiteValue> = []
        for row in try db.run(
            "SELECT id, \"to\" FROM \(links) WHERE relation IN (\(placeholders(names.count))) AND \"from\" = ?",
            names.map { .text($0) } + [ownerID]
        ) {
            let target = row["to"] ?? .null
            if wanted.contains(target) {
                // The first link to a wanted target stays, and any duplicate goes.
                if linked.insert(target).inserted { continue }
            } else {
                guard try wasRemoved(target, from: loaded) else { continue }
                // A link a server delivered before its target stays until the target arrives.
                if syncEnabled, let type = field.relationship?.target, try !rowExists(type.table, id: target) { continue }
            }
            try deleteRow(_RecordLink.table, id: row["id"]!)
        }
        let from = try ValueCoding.decode(UUID.self, from: ownerID)
        let now = Date()
        for (index, target) in wanted.filter({ !linked.contains($0) }).enumerated() {
            let link = _RecordLink(
                relation: names[0], from: from, to: try ValueCoding.decode(UUID.self, from: target),
                created: now.addingTimeInterval(Double(index) / 1000)
            )
            try save(link)
        }
    }

    /// Whether a related record missing from a relationship's value was taken out of it: true unless the
    /// value was fetched without it, which means it arrived later.
    private func wasRemoved(_ id: SQLiteValue, from loaded: Set<UUID>?) throws -> Bool {
        guard let loaded else { return true }
        return loaded.contains(try ValueCoding.decode(UUID.self, from: id))
    }

    /// The names a many-to-many property's links are stored under: `Owner.property`, then its earlier names.
    static func relationNames<R: Record>(_ type: R.Type, field: RecordSchema<R>.Field) -> [String] {
        ([field.name] + field.previousNames).map { R.table + "." + $0 }
    }

    /// The names the links behind a many-to-many key path, such as `\Recipe.tags`, are stored under.
    static func relationNames(_ keyPath: AnyKeyPath) -> [String]? {
        func names<O: Record>(_ type: O.Type) -> [String]? {
            guard let field = O.cachedSchema.field(for: keyPath), case .links? = field.relationship else { return nil }
            return relationNames(O.self, field: field)
        }
        guard let owner = Swift.type(of: keyPath).rootType as? any Record.Type else { return nil }
        return names(owner)
    }

    /// Sets a record's pointer column, which is a change to the record.
    private func setReference(_ table: String, column: String, id: SQLiteValue, to value: SQLiteValue) throws {
        try beforeChange(table, id: id)
        structuralChanges += 1
        try db.run("UPDATE \(quoted(table)) SET \(quoted(column)) = ? WHERE id = ?", [value, id])
        try logChange(table, id: id)
    }

    // MARK: Deleting

    /// Deletes a record and applies each relationship's delete rule.
    func delete<R: Record>(_ record: R) throws {
        try delete(R.self, id: record.id)
    }

    func delete<R: Record>(_ type: R.Type, id: R.ID) throws {
        try registerForJournal(R.self)
        let id = try ValueCoding.encode(id)
        try transaction { try deleteRow(R.table, id: id) }
    }

    /// Deletes every record that matches the predicate, or every record of the type without one.
    func delete<R: Record>(_ type: R.Type, where predicate: Predicate<R>?) throws {
        try registerForJournal(R.self)
        try transaction {
            guard tableExists(R.table) else { return }
            try prepare(R.self)
            let ids: [SQLiteValue]
            if let (clause, bindings) = try whereClause(predicate) {
                ids = try db.run("SELECT id FROM \(quoted(R.table))\(clause)", bindings).map { $0["id"]! }
            } else {
                ids = try fetchRecords(R.self, where: predicate, order: RecordOrder([]), page: nil).map { try $0.sqlID }
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
            pointerInfo = nil
            prepared = []
            try? FileManager.default.removeItem(at: assetsDirectory)
            // Registered types get their tables back, ready for records from a server.
            let types = Array(registered.values)
            registered = [:]
            try register(types)
        }
    }

    /// Deletes by table name, so cascades work for types this process has never loaded. The records that
    /// point here go too, or lose their pointer, by their action.
    func deleteRow(_ table: String, id: SQLiteValue) throws {
        guard try rowExists(table, id: id) else { return }
        if case .incompatibleRecord(_, let bad)? = undecodable[table], (try? ValueCoding.encode(bad)) == id {
            setUndecodable(nil, in: table)
        }
        try beforeChange(table, id: id)
        structuralChanges += 1
        let assets = try db.run(
            "SELECT name FROM \"_records_assets\" WHERE owner_table = ? AND owner_id = ?", [.text(table), id]
        )
        for case .text(let name)? in assets.map({ $0["name"] }) {
            try releaseAsset(named: name)
        }
        try logChange(table, id: id, kind: .delete)
        // The row goes first, so a cascade that comes back around finds it gone.
        try db.run("DELETE FROM \(quoted(table)) WHERE id = ?", [id])
        for pointer in pointers() where pointer.target == nil || pointer.target == table {
            guard tableExists(pointer.table), columns[pointer.table, default: []].contains(pointer.field) else { continue }
            for row in try db.run("SELECT id FROM \(quoted(pointer.table)) WHERE \(quoted(pointer.field)) = ?", [id]) {
                if pointer.action == .deleteSelf {
                    cascading += 1
                    defer { cascading -= 1 }
                    try deleteRow(pointer.table, id: row["id"]!)
                } else {
                    try setReference(pointer.table, column: pointer.field, id: row["id"]!, to: .null)
                }
            }
        }
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
        try fetch(type, ids: ids, sorted: false)
    }

    /// Fetches records by ID, sorted by ID, skipping any that no longer exist. Use it to load an
    /// inverse relationship: `container.fetch(Cookbook.self, ids: recipe.cookbookIDs)`.
    func fetch<R: Record>(_ type: R.Type, ids: Set<UUID>) throws -> [R] {
        try fetch(type, ids: Array(ids), sorted: true)
    }

    private func fetch<R: Record>(_ type: R.Type, ids: [R.ID], sorted: Bool) throws -> [R] {
        try locked {
            guard tableExists(R.table) else { return [] }
            try prepare(R.self)
            let ids = try (sorted ? ids.sorted { $0.precedes($1) } : ids).map { try ValueCoding.encode($0) }
            var rows: [SQLiteValue: [String: SQLiteValue]] = [:]
            for chunk in ids.chunked(into: Self.batchSize) {
                for row in try db.run("SELECT \(recordColumns(R.table)) FROM \(quoted(R.table)) WHERE id IN (\(placeholders(chunk.count)))", Array(chunk)) {
                    rows[row["id"]!] = row
                }
            }
            let found = ids.compactMap { rows[$0] }
            return try prefetching(R.self, rows: found) {
                try decodeRows(R.self, found)
            }
        }
    }

    /// Fetches records matching a predicate, in the descriptors' order and then by ID.
    ///
    /// Simple predicates on a record's own properties run as SQL. Anything else is evaluated in memory.
    func fetch<R: Record>(_ type: R.Type = R.self, where predicate: Predicate<R>? = nil, sortBy: [SortDescriptor<R>] = []) throws -> [R] {
        try locked { try fetchRecords(R.self, where: predicate, order: RecordOrder(sortBy), page: nil) }
    }

    /// Fetches one page of records: at most `limit` of them, starting `offset` records into the results.
    ///
    /// The slice's indices are the records' positions in the full results, so a page fetched with an
    /// offset of 40 starts at index 40. The page is read straight from SQL when the predicate translates.
    func fetch<R: Record>(
        _ type: R.Type = R.self,
        where predicate: Predicate<R>? = nil,
        sortBy: [SortDescriptor<R>] = [],
        limit: Int,
        offset: Int = 0
    ) throws -> RecordSlice<R> {
        precondition(limit >= 0 && offset >= 0, "limit and offset must not be negative")
        return try locked {
            RecordSlice(try fetchRecords(R.self, where: predicate, order: RecordOrder(sortBy), page: (limit, offset)), startIndex: offset)
        }
    }

    func count<R: Record>(_ type: R.Type, where predicate: Predicate<R>? = nil) throws -> Int {
        try locked {
            guard tableExists(R.table) else { return 0 }
            try prepare(R.self)
            guard let (clause, bindings) = try whereClause(predicate) else {
                return try fetchRecords(R.self, where: predicate, order: RecordOrder([]), page: nil).count
            }
            let rows = try db.run("SELECT COUNT(*) AS n FROM \(quoted(R.table))\(clause)", bindings)
            guard case .integer(let n) = rows.first?["n"] else { return 0 }
            return Int(n)
        }
    }

    /// The IDs of the records that match, in order, without decoding the records when the predicate and
    /// sort translate to SQL.
    func ids<R: Record>(
        _ type: R.Type, where predicate: Predicate<R>?, sortBy: [SortDescriptor<R>] = [], page: (limit: Int, offset: Int)?
    ) throws -> [UUID] {
        try locked {
            guard tableExists(R.table) else { return [] }
            try prepare(R.self)
            let order = RecordOrder(sortBy)
            guard let (clause, bindings) = try whereClause(predicate), let orderBy = try orderClause(order) else {
                return try fetchRecords(R.self, where: predicate, order: order, page: page).map(\.id)
            }
            var sql = "SELECT id FROM \(quoted(R.table))\(clause)\(orderBy)"
            var values = bindings
            if let page {
                sql += " LIMIT ? OFFSET ?"
                values += [.integer(Int64(page.limit)), .integer(Int64(page.offset))]
            }
            return try db.run(sql, values).map { try ValueCoding.decode(UUID.self, from: $0["id"] ?? .null) }
        }
    }

    /// The SQL `WHERE` clause for a predicate: empty for none, or nil when it must run in memory.
    private func whereClause<R: Record>(_ predicate: Predicate<R>?) throws -> (String, [SQLiteValue])? {
        guard let predicate else { return ("", []) }
        guard let clause = try? PredicateTranslator.translate(predicate) else { return nil }
        return try whereClause(clause, for: R.self)
    }

    /// The clause as SQL for a type, or nil when SQL can't run it.
    private func whereClause<R: Record>(_ clause: PredicateTranslator.Clause, for type: R.Type) throws -> (String, [SQLiteValue])? {
        // A join table that does not exist yet means no links; SQL would fail on it, so filter in memory.
        guard clause.relations.allSatisfy(tableExists) else { return nil }
        // A synced timestamp isn't a column, so a predicate on it runs in memory.
        let synced = Set(R.cachedSchema.fields.filter { $0.timestamp == .synced }.map { $0.name })
        if clause.columns.contains(where: { $0.table == R.table && synced.contains($0.column) }) {
            return nil
        }
        for (table, column) in clause.columns {
            try ensureColumns([column], in: table)
        }
        return (" WHERE " + clause.sql, clause.bindings)
    }

    /// The SQL `ORDER BY` clause for an order, or nil when it sorts in Swift.
    private func orderClause<R: Record>(_ order: RecordOrder<R>) throws -> String? {
        guard let columns = order.columns else { return nil }
        try ensureColumns(columns.map(\.column), in: R.table)
        return " ORDER BY " + (columns.map { quoted($0.column) + ($0.descending ? " DESC" : "") } + ["id"]).joined(separator: ", ")
    }

    /// Loads matching records in order, optionally one page of them.
    ///
    /// When only some of a predicate's `&&` terms translate, SQL narrows the rows by those and the whole
    /// predicate checks the rest in memory, so a fetch never reads more of the table than it must. An
    /// order SQL can't run sorts in Swift, after every match is loaded.
    private func fetchRecords<R: Record>(
        _ type: R.Type, where predicate: Predicate<R>?, order: RecordOrder<R>, page: (limit: Int, offset: Int)?
    ) throws -> [R] {
        guard tableExists(R.table) else { return [] }
        try prepare(R.self)
        var translated = try whereClause(predicate)
        let exactFilter = translated != nil
        if !exactFilter, let predicate, let clause = PredicateTranslator.translateTerms(predicate) {
            translated = try whereClause(clause, for: R.self)
        }
        let orderBy = try orderClause(order)
        let exact = exactFilter && orderBy != nil
        var sql = "SELECT \(recordColumns(R.table)) FROM \(quoted(R.table))" + (translated?.0 ?? "") + (orderBy ?? " ORDER BY id")
        var bindings = translated?.1 ?? []
        if let page, exact {
            sql += " LIMIT ? OFFSET ?"
            bindings += [.integer(Int64(page.limit)), .integer(Int64(page.offset))]
        }
        let rows = try db.run(sql, bindings)
        var records = try prefetching(R.self, rows: rows) {
            try decodeRows(R.self, rows)
        }
        if !exactFilter, let predicate {
            records = try records.filter { try predicate.evaluate($0) }
        }
        if orderBy == nil {
            records = order.sorted(records)
        }
        if !exact {
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

    /// Rows and relationships loaded ahead of decoding, so a fetch of many records runs one query per
    /// relationship instead of one per record.
    private final class Prefetch {
        /// Rows by table, then ID.
        var rows: [String: [SQLiteValue: [String: SQLiteValue]]] = [:]
        /// Each owner's related records' IDs in order, by `Owner.property`.
        var related: [String: [SQLiteValue: [SQLiteValue]]] = [:]
        /// The owners linking to each record, by the owner's `Owner.property`.
        var owners: [String: [SQLiteValue: [SQLiteValue]]] = [:]
        /// Rows whose relationships are loaded.
        var visited: Set<RowKey> = []
    }

    private var prefetched: Prefetch?
    static let batchSize = 500

    func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Loads every relationship reachable from `rows`, level by level, then runs `body` to decode them.
    private func prefetching<R: Record, T>(_ type: R.Type, rows: [[String: SQLiteValue]], _ body: () throws -> T) throws -> T {
        let owner = prefetched == nil
        let cache = prefetched ?? Prefetch()
        prefetched = cache
        defer { if owner { prefetched = nil } }

        for row in rows {
            cache.rows[R.table, default: [:]][row["id"]!] = row
        }
        var frontier: [(type: any Record.Type, ids: [SQLiteValue])] = [(R.self, rows.map { $0["id"]! })]
        while let (type, ids) = frontier.popLast() {
            frontier += try prefetchRelated(type, ids: ids, into: cache)
        }
        return try body()
    }

    /// Loads one level of relationships for records of a type, and returns the records it reached.
    private func prefetchRelated<O: Record>(
        _ type: O.Type, ids: [SQLiteValue], into cache: Prefetch
    ) throws -> [(type: any Record.Type, ids: [SQLiteValue])] {
        let ids = ids.filter { cache.visited.insert(RowKey(table: O.table, id: $0)).inserted }
        guard !ids.isEmpty else { return [] }
        var reached: [(type: any Record.Type, ids: [SQLiteValue])] = []
        for field in O.cachedSchema.fields {
            let key = O.table + "." + field.name
            if let relationship = field.relationship {
                var related = Dictionary(uniqueKeysWithValues: ids.map { ($0, [SQLiteValue]()) })
                let pairs: [(owner: SQLiteValue, id: SQLiteValue)]
                switch relationship {
                case .children(let type, let pointer):
                    pairs = try prefetchChildren(type, pointer: pointer, owners: ids, into: cache)
                case .links(let type):
                    pairs = try prefetchLinks(type, names: Self.relationNames(O.self, field: field), owners: ids, into: cache)
                }
                for pair in pairs {
                    related[pair.owner, default: []].append(pair.id)
                }
                cache.related[key, default: [:]].merge(related) { $1 }
                reached.append((relationship.target, pairs.map(\.id)))
            } else if let inverse = field.inverse, let names = Self.relationNames(inverse) {
                guard tableExists(_RecordLink.table) else { continue }
                var owners = Dictionary(uniqueKeysWithValues: ids.map { ($0, [SQLiteValue]()) })
                for chunk in ids.chunked(into: Self.batchSize) {
                    for link in try db.run(
                        """
                        SELECT "from", "to" FROM \(quoted(_RecordLink.table))
                        WHERE relation IN (\(placeholders(names.count))) AND "to" IN (\(placeholders(chunk.count)))
                        """,
                        names.map { .text($0) } + Array(chunk)
                    ) {
                        owners[link["to"]!, default: []].append(link["from"]!)
                    }
                }
                cache.owners[names[0], default: [:]].merge(owners) { $1 }
            }
        }
        return reached
    }

    /// The children pointing at each owner, in ID order, with their rows cached.
    private func prefetchChildren(
        _ type: any Record.Type, pointer: AnyKeyPath, owners: [SQLiteValue], into cache: Prefetch
    ) throws -> [(owner: SQLiteValue, id: SQLiteValue)] {
        func load<C: Record>(_ type: C.Type) throws -> [(owner: SQLiteValue, id: SQLiteValue)] {
            guard let column = C.fieldName(for: pointer), tableExists(C.table) else { return [] }
            try prepare(C.self)
            try ensureColumns([column], in: C.table)
            var pairs: [(owner: SQLiteValue, id: SQLiteValue)] = []
            for chunk in owners.chunked(into: Self.batchSize) {
                for row in try db.run(
                    """
                    SELECT \(recordColumns(C.table)) FROM \(quoted(C.table))
                    WHERE \(quoted(column)) IN (\(placeholders(chunk.count))) ORDER BY \(quoted(column)), id
                    """,
                    Array(chunk)
                ) {
                    let id = row["id"]!
                    cache.rows[C.table, default: [:]][id] = row
                    pairs.append((row[column]!, id))
                }
            }
            return pairs
        }
        return try load(type)
    }

    /// The records each owner links to, in the order they were linked, with their rows cached.
    private func prefetchLinks(
        _ type: any Record.Type, names: [String], owners: [SQLiteValue], into cache: Prefetch
    ) throws -> [(owner: SQLiteValue, id: SQLiteValue)] {
        guard tableExists(_RecordLink.table), tableExists(type.table) else { return [] }
        let target = quoted(type.table)
        var pairs: [(owner: SQLiteValue, id: SQLiteValue)] = []
        for chunk in owners.chunked(into: Self.batchSize) {
            for row in try db.run(
                """
                SELECT l."from" AS "_records_owner", \(recordColumns(type.table))
                FROM \(quoted(_RecordLink.table)) AS l JOIN \(target) ON \(target).id = l."to"
                WHERE l.relation IN (\(placeholders(names.count))) AND l."from" IN (\(placeholders(chunk.count)))
                ORDER BY l."from", l.created, l.id
                """,
                names.map { .text($0) } + Array(chunk)
            ) {
                var row = row
                let owner = row.removeValue(forKey: "_records_owner")!
                let id = row["id"]!
                cache.rows[type.table, default: [:]][id] = row
                pairs.append((owner, id))
            }
        }
        return pairs
    }

    /// Decodes rows, skipping and reporting any that don't decode as the type.
    private func decodeRows<R: Record>(_ type: R.Type, _ rows: [[String: SQLiteValue]]) throws -> [R] {
        try rows.compactMap { row -> R? in
            do {
                let record = try decodeRow(R.self, row: row)
                if case .incompatibleRecord(_, let id)? = undecodable[R.table], id == record.id {
                    setUndecodable(nil, in: R.table)
                }
                return record
            } catch let error as RecordsError {
                guard case .incompatibleRecord = error else { throw error }
                if undecodable[R.table] == nil {
                    setUndecodable(error, in: R.table)
                }
                return nil
            }
        }
    }

    /// Notes the bad record a type has, or that it has none now, and reports the first left.
    private func setUndecodable(_ error: RecordsError?, in table: String) {
        undecodable[table] = error
        undecodableChanged?(undecodable.sorted { $0.key < $1.key }.first?.value)
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
            try db.execute("CREATE TABLE \(quoted(table)) (\"id\" PRIMARY KEY)")
            columns[table] = ["id"]
        }
    }

    /// Applies `@Renamed` and `@Indexed` to a table the first time this container uses its type: old
    /// columns, join tables and asset entries take the new name, and indexed columns get an index.
    func prepare<R: Record>(_ type: R.Type) throws {
        guard !prepared.contains(ObjectIdentifier(R.self)), tableExists(R.table) else { return }
        for field in R.cachedSchema.fields {
            for old in field.previousNames {
                try rename(field: old, to: field.name, in: R.table)
            }
            if field.timestamp == .created || field.timestamp == .modified {
                try ensureColumns([field.name], in: R.table)
            }
            // A pointer is indexed too, since loading and cascading look records up by it.
            if field.isIndexed || field.isPointer {
                try ensureColumns([field.name], in: R.table)
                try db.execute(
                    "CREATE INDEX IF NOT EXISTS \(quoted(R.table + "." + field.name + ".index")) ON \(quoted(R.table)) (\(quoted(field.name)))"
                )
            }
            if field.isPointer {
                try notePointer(PointerInfo(table: R.table, field: field.name, target: field.pointerTarget?.table, action: field.action))
            }
            if case .children(let type, let pointer)? = field.relationship, let order = field.order {
                try indexChildren(type, pointer: pointer, order: order)
            }
        }
        if R.self == _RecordLink.self {
            let table = quoted(R.table)
            try ensureColumns(["relation", "from", "to", "created"], in: R.table)
            try db.execute("""
                CREATE INDEX IF NOT EXISTS \(quoted(R.table + ".from")) ON \(table) (relation, "from", created);
                CREATE INDEX IF NOT EXISTS \(quoted(R.table + ".to")) ON \(table) (relation, "to");
                """)
        }
        stampColumns[R.table] = (
            R.cachedSchema.fields.filter { $0.timestamp == .created }.map { $0.name }, R.cachedSchema.fields.filter { $0.timestamp == .modified }.map { $0.name }
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
        try db.run("UPDATE \"_records_assets\" SET field = ? WHERE owner_table = ? AND field = ?", [.text(new), .text(table), .text(old)])
    }

    private static let internalColumns: Set<String> = ["id"]

    /// The columns a record decodes from.
    private func recordColumns(_ table: String) -> String {
        if let list = columnLists[table] { return list }
        let list = columns[table, default: []].sorted().map { quoted(table) + "." + quoted($0) }.joined(separator: ", ")
        columnLists[table] = list
        return list
    }

    /// Adds any missing columns. Columns have no declared type, so SQLite stores each value as given.
    func ensureColumns(_ names: [String], in table: String) throws {
        try ensureTable(table)
        for name in names where !columns[table, default: []].contains(name) {
            try db.execute("ALTER TABLE \(quoted(table)) ADD COLUMN \(quoted(name))")
            columns[table, default: []].insert(name)
        }
    }

    /// Every stored pointer, by the table it lives in.
    func pointers() -> [PointerInfo] {
        if let pointerInfo { return pointerInfo }
        let rows = (try? db.run("SELECT * FROM \"_records_pointers\"")) ?? []
        let loaded = rows.compactMap { row -> PointerInfo? in
            guard case .text(let table) = row["record_table"], case .text(let field) = row["field"],
                  case .text(let action) = row["action"] else { return nil }
            var target: String?
            if case .text(let name) = row["target_table"] { target = name }
            return PointerInfo(table: table, field: field, target: target, action: ReferenceAction(rawValue: action) ?? .nullify)
        }
        pointerInfo = loaded
        return loaded
    }

    private func notePointer(_ info: PointerInfo) throws {
        guard !pointers().contains(info) else { return }
        try db.run(
            "INSERT OR REPLACE INTO \"_records_pointers\" (record_table, field, target_table, action) VALUES (?, ?, ?, ?)",
            [.text(info.table), .text(info.field), info.target.map { .text($0) } ?? .null, .text(info.action.rawValue)]
        )
        pointerInfo = pointers().filter { !($0.table == info.table && $0.field == info.field) } + [info]
    }

    /// Indexes a child table on its pointer and the columns a relationship sorts it by, so SQLite reads
    /// each owner's children already in order.
    private func indexChildren(_ type: any Record.Type, pointer: AnyKeyPath, order: RelationshipOrder) throws {
        guard !order.isEmpty, let columns = order.columns(), let column = type.fieldName(for: pointer) else { return }
        let names = [column] + columns.map(\.column)
        try ensureColumns(names, in: type.table)
        try db.execute(
            "CREATE INDEX IF NOT EXISTS \(quoted(([type.table] + names + ["index"]).joined(separator: "."))) "
                + "ON \(quoted(type.table)) (\(names.map(quoted).joined(separator: ", ")))"
        )
    }
}

extension RecordStore: RelationLoader {
    func loadRelated<R: Record>(_ type: R.Type, ownerID: SQLiteValue, field: RecordSchema<R>.Field) throws -> [any Record] {
        guard let relationship = field.relationship else { return [] }
        func load<T: Record>(_ type: T.Type) throws -> [any Record] {
            try relatedIDs(R.self, ownerID: ownerID, field: field).compactMap { try fetchRow(T.self, id: $0) }
        }
        let records = try load(relationship.target)
        guard let order = field.order, !order.isEmpty else { return records }
        return order.sort(records)
    }

    func hasRelated<R: Record>(_ type: R.Type, ownerID: SQLiteValue, field: RecordSchema<R>.Field) throws -> Bool {
        try !relatedIDs(R.self, ownerID: ownerID, field: field).isEmpty
    }

    /// The IDs of the records a relationship holds, before any `sort:`: children in ID order and links in
    /// the order they were made. A link whose target hasn't arrived is left out.
    private func relatedIDs<R: Record>(_ type: R.Type, ownerID: SQLiteValue, field: RecordSchema<R>.Field) throws -> [SQLiteValue] {
        if let ids = prefetched?.related[R.table + "." + field.name]?[ownerID] {
            return ids
        }
        switch field.relationship {
        case .children(let type, let pointer)?:
            guard let column = type.fieldName(for: pointer), tableExists(type.table),
                  columns[type.table, default: []].contains(column) else { return [] }
            return try db.run("SELECT id FROM \(quoted(type.table)) WHERE \(quoted(column)) = ? ORDER BY id", [ownerID]).map { $0["id"]! }
        case .links(let type)?:
            guard tableExists(_RecordLink.table), tableExists(type.table) else { return [] }
            let names = Self.relationNames(R.self, field: field)
            return try db.run(
                """
                SELECT l."to" AS id FROM \(quoted(_RecordLink.table)) AS l JOIN \(quoted(type.table)) AS t ON t.id = l."to"
                WHERE l.relation IN (\(placeholders(names.count))) AND l."from" = ? ORDER BY l.created, l.id
                """,
                names.map { .text($0) } + [ownerID]
            ).map { $0["id"]! }
        case nil:
            return []
        }
    }

    func loadInverse(targetID: SQLiteValue, inverse: AnyKeyPath) throws -> [SQLiteValue] {
        guard let names = Self.relationNames(inverse) else { throw RecordsError.unknownInverse("\(inverse)") }
        if let owners = prefetched?.owners[names[0]]?[targetID] {
            return owners
        }
        guard tableExists(_RecordLink.table) else { return [] }
        return try db.run(
            "SELECT \"from\" FROM \(quoted(_RecordLink.table)) WHERE relation IN (\(placeholders(names.count))) AND \"to\" = ?",
            names.map { .text($0) } + [targetID]
        ).map { $0["from"]! }
    }

    func assetURL(named name: String) -> URL {
        assetsDirectory.appendingPathComponent(name)
    }

    /// When the server acknowledged the record as it is now, or `nil` while it has unsent changes or has
    /// never synced.
    func syncedDate(table: String, id: SQLiteValue) throws -> Date? {
        let row = try db.run(
            "SELECT synced_at, acked, version, kind FROM \"_records_meta\" WHERE record_table = ? AND record_id = ? AND known = 1",
            [.text(table), id]
        ).first
        guard let row, case .real(let time) = row["synced_at"], !Self.isPending(row) else { return nil }
        return Date(timeIntervalSince1970: time)
    }
}

/// One page of fetched records. Its indices are the records' positions in the full results, so a page
/// fetched with an offset of 40 starts at index 40. It is read-only: edit a record and save it to change it.
package struct RecordSlice<R: Record>: RandomAccessCollection, Sendable {
    private let records: [R]
    package let startIndex: Int

    init(_ records: [R], startIndex: Int) {
        self.records = records
        self.startIndex = startIndex
    }

    package var endIndex: Int { startIndex + records.count }

    package subscript(position: Int) -> R {
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
    /// Whether a server holds a copy of the record, from a download or an upload it confirmed.
    private func serverHas(_ table: String, id: SQLiteValue) throws -> Bool {
        let row = try db.run("SELECT known, tag FROM \"_records_meta\" WHERE record_table = ? AND record_id = ?", [.text(table), id]).first
        return row?["known"] == .integer(1) || (row?["tag"] ?? .null) != .null
    }

    func logChange(_ table: String, id: SQLiteValue, kind: RecordChange.Kind = .save) throws {
        changedData = true
        // A record that goes with a server delete is sent, since it may be one the deleting device never
        // saw, such as a step added elsewhere at the same time. Its own delete usually arrives alongside.
        if applyingSynced > 0, try !(kind == .delete && cascading > 0 && serverHas(table, id: id)) {
            // The server already has this change. A record it deleted has nothing left to send.
            if kind == .delete {
                try dropLogEntry(table, id: id)
            }
            return
        }
        let key = RowKey(table: table, id: id)
        if kind == .save, logged.last(where: { $0[key] != nil })?[key] == .save { return }
        logged[logged.count - 1][key] = kind

        let previous = try db.run(
            "SELECT version FROM \"_records_meta\" WHERE record_table = ? AND record_id = ?", [.text(table), id]
        ).first?["version"]
        guard case .integer(let last) = previous ?? .integer(0) else { return }
        let version = SQLiteValue.integer(last + 1)
        let now = SQLiteValue.real(Date().timeIntervalSince1970)
        if kind == .save {
            if let stamps = stampColumns[table] {
                let sets = stamps.created.map { "\(quoted($0)) = COALESCE(\(quoted($0)), ?1)" } + stamps.modified.map { "\(quoted($0)) = ?1" }
                if !sets.isEmpty {
                    try db.run("UPDATE \(quoted(table)) SET \(sets.joined(separator: ", ")) WHERE id = ?2", [now, id])
                }
            }
        }
        // Replacing the row gives it a new sequence number at the end of the log, and carries its sync state over.
        try db.run(
            """
            INSERT OR REPLACE INTO "_records_meta"
                (record_table, record_id, kind, version, time, acked, known, tag, snapshot, extra, synced_at, parked)
            SELECT ?1, ?2, ?3, ?4, ?5, COALESCE(m.acked, 0), COALESCE(m.known, 0), m.tag, m.snapshot, m.extra, m.synced_at,
                m.parked
            FROM (SELECT 1) LEFT JOIN "_records_meta" m ON m.record_table = ?1 AND m.record_id = ?2
            """,
            [.text(table), id, .text(kind.rawValue), version, now]
        )
    }

    /// The token of the latest change, to store before you start reading changes.
    var changeToken: ChangeToken {
        get throws {
            try locked {
                let row = try db.run("SELECT seq FROM sqlite_sequence WHERE name = '_records_meta'").first
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
                "SELECT * FROM \"_records_meta\" WHERE seq > ? AND kind IS NOT NULL ORDER BY seq", [.integer(token.rawValue)]
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
            let id = try ValueCoding.encode(id)
            guard try rowExists(R.table, id: id) else { return nil }
            let row = try syncRow(R.table, id: id)
            let saved = row?["kind"] == .text(RecordChange.Kind.save.rawValue)
            var modified: Date?
            if saved, case .real(let time)? = row?["time"] { modified = Date(timeIntervalSince1970: time) }
            var tag: Data?
            if case .blob(let data)? = row?["tag"] { tag = data }
            return RecordMetadata(version: saved ? Int(row?["version"]?.integerValue ?? 0) : 0, modified: modified, tag: tag)
        }
    }

    /// Stores opaque sync data with a record without changing its version or logging a change.
    func setTag<R: Record>(_ tag: Data?, for type: R.Type, id: R.ID) throws {
        try transaction {
            let id = try ValueCoding.encode(id)
            guard tableExists(R.table), try rowExists(R.table, id: id) else { return }
            try updateSyncRow(R.table, id: id, ["tag": tag.map { .blob($0) } ?? .null])
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
