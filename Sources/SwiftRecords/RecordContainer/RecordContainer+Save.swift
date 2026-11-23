import Foundation
import Versioning
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension RecordContainer {
    static let createTable = """
        CREATE TABLE IF NOT EXISTS record (
            id TEXT NOT NULL,
            zone TEXT NOT NULL,
            owner TEXT NOT NULL,
            type TEXT NOT NULL,
            metadata BLOB,
            base TEXT,
            ours TEXT,
            theirs TEXT,
            sent TEXT,
            is_deleted INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            PRIMARY KEY (id, zone, owner)
        );
        CREATE TABLE IF NOT EXISTS engine_state (
            id INTEGER PRIMARY KEY CHECK (id = 0),
            data BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS record_schema (
            name TEXT PRIMARY KEY NOT NULL,
            schema TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS record_change (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            txn INTEGER,
            id TEXT NOT NULL,
            zone TEXT NOT NULL,
            owner TEXT NOT NULL,
            type TEXT NOT NULL,
            kind TEXT NOT NULL,
            timestamp REAL NOT NULL DEFAULT ((julianday('now') - 2440587.5) * 86400.0),
            author TEXT
        );
        CREATE TRIGGER IF NOT EXISTS record_insert BEFORE INSERT ON record BEGIN
            INSERT INTO record_change (id, zone, owner, type, kind) VALUES (NEW.id, NEW.zone, NEW.owner, NEW.type,
                CASE WHEN NEW.is_deleted THEN 'delete'
                     WHEN EXISTS (SELECT 1 FROM record WHERE id = NEW.id AND zone = NEW.zone AND owner = NEW.owner) THEN 'update'
                     ELSE 'insert' END);
        END;
        CREATE TRIGGER IF NOT EXISTS record_delete AFTER DELETE ON record BEGIN
            INSERT INTO record_change (id, zone, owner, type, kind) VALUES (OLD.id, OLD.zone, OLD.owner, OLD.type, 'delete');
        END
        """

    /// How long a `record_change` row is kept, in seconds, for other connections to read.
    static let changeLifetime: TimeInterval = 3600

    /// Saves `record` as this device's version: `ours`, waiting to upload.
    ///
    /// The row's id comes from the value at `id`, by ``recordID(for:type:)``, and `zone`,
    /// so the same record saved to another zone is another row. A new id adds a row. An
    /// existing one replaces `ours`, clears `isDeleted` and `error`, and keeps
    /// `base`, `theirs`, `metadata` and the zone, in one statement. Each `@Asset` file is
    /// copied into the container, so the row keeps it however the original changes. Asserts that a record
    /// saved to ``Zone/public`` has no `@Encrypted` values, which the public database rejects.
    ///
    /// ```swift
    /// try container.save(our: page, id: \.slug, zone: "Pages")
    /// ```
    func save<Record: Encodable, ID: Encodable>(our record: Record, id: KeyPath<Record, ID>, zone: Zone) throws {
        assert(zone != .public || !Mirror(reflecting: record).properties.contains { $0.value is any EncryptedValue },
               "The public database cannot store @Encrypted values, so \(Record.self) cannot be saved to Zone.public.")
        let id = RowID(name: try Self.recordID(for: record[keyPath: id], type: Self.recordType(of: Record.self)), zone: zone)
        let json = try JSONRepresentation(record)
        let ours = try Self.text(portable(storingAssets(of: record, in: json, id: id), id: id))
        let type = Self.recordType(of: Record.self)
        try transaction { () throws(DatabaseError) in
            try run("""
                INSERT INTO record (id, zone, owner, type, ours) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (id, zone, owner) DO UPDATE SET type = excluded.type, ours = excluded.ours, is_deleted = 0, error = NULL
                """, id.name.uuidString, zone.name, zone.owner, type, ours)
            if let row = try row(id: id) { sweepAssets(of: row) }
        }
    }

    /// Saves an `Identifiable` `record` as this device's version, identified by its `id`.
    func save<Record: Encodable & Identifiable>(our record: Record, zone: Zone) throws where Record.ID: Encodable {
        try save(our: record, id: \.id, zone: zone)
    }

    /// Saves the server's version of the record `id` in `zone`, with its system fields as `metadata`.
    ///
    /// A new record, or one with no local changes, takes `json` as its `base`. With local
    /// changes waiting, `json` merges into `ours` first, by the registered type's own merge.
    /// See ``Row/receive(_:merging:)``. When `type` is not registered, a merge cannot run, so
    /// `json` waits in `theirs` with the reason in `error`.
    func save(their json: JSONRepresentation, id: UUID, zone: Zone, type: String, metadata: Data?) throws(DatabaseError) {
        // Looked up before the row is locked, since the lookup takes the same lock.
        let registered = Result { try registeredType(named: type) }
        let rowID = RowID(name: id, zone: zone)
        try update(id: rowID, inserting: Row(id: id, zone: zone, type: type)) { row in
            row.metadata = metadata
            row.receive(json) { ours, theirs, base in
                try merged(ours, with: theirs, from: base, as: registered.get(), id: rowID)
            }
        }
    }

    /// Deletes `record` in `zone` on this device, identified by the value at `id`, as
    /// ``delete(id:)`` describes. A copy of the record in another zone stays.
    ///
    /// ```swift
    /// try container.delete(our: page, id: \.slug, zone: "Pages")
    /// ```
    func delete<Record: Encodable, ID: Encodable>(our record: Record, id: KeyPath<Record, ID>, zone: Zone) throws {
        try delete(id: RowID(name: Self.recordID(for: record[keyPath: id], type: Self.recordType(of: Record.self)), zone: zone))
    }

    /// Deletes an `Identifiable` `record` in `zone` on this device, identified by its `id`.
    func delete<Record: Encodable & Identifiable>(our record: Record, zone: Zone) throws where Record.ID: Encodable {
        try delete(our: record, id: \.id, zone: zone)
    }

    /// Deletes the record `id` on this device.
    ///
    /// A record the server has never confirmed is removed at once, since there is nothing
    /// to delete there. Any other record waits to upload its delete, and its unsent changes,
    /// any version waiting to merge, and any error are dropped. Saving the record again
    /// before the delete uploads undoes it.
    func delete(id: RowID) throws(DatabaseError) {
        try transaction { () throws(DatabaseError) in
            guard var row = try row(id: id) else { return }
            guard row.metadata != nil || row.base != nil else { return try remove(id: id) }
            row.isDeleted = true
            row.ours = .none
            row.theirs = .none
            row.error = nil
            try write(row)
        }
    }

    /// Saves that the server no longer has the record `id`, because it confirmed this
    /// device's delete or another device deleted it.
    ///
    /// The row is removed, unless this device has unsent changes. Those win: the row forgets
    /// the server's version and keeps `ours`, so the next send creates the record again.
    func save(deleted id: RowID) throws(DatabaseError) {
        try transaction(author: Self.syncAuthor) { () throws(DatabaseError) in
            guard let row = try row(id: id) else { return }
            guard let ours = row.ours, !row.isDeleted else { return try remove(id: id) }
            try write(Row(id: id.name, zone: row.zone, type: row.type, ours: ours))
        }
    }

    /// Removes every row on this device, and the engine's state, sending nothing, as when the
    /// iCloud account signs out or changes. Unlike ``delete(id:)``, nothing is deleted on the server.
    func clear() throws(DatabaseError) {
        try transaction { () throws(DatabaseError) in
            try run("DELETE FROM record")
            try run("DELETE FROM engine_state")
            try? FileManager.default.removeItem(at: assets)
        }
    }

    /// Removes every row in `zone` on this device, sending nothing, as when the zone was
    /// deleted on the server. Unsent changes in the zone are dropped, since the zone they
    /// belong to is gone.
    ///
    /// When `resending` is `true`, as when the server lost the zone because the user reset
    /// their encrypted data, each record is kept instead and sent again as new: its content,
    /// this device's changes or else the server's last version, becomes `ours`, and the rest
    /// is forgotten. A record waiting to upload its delete is removed.
    func clear(in zone: Zone, resending: Bool = false) throws(DatabaseError) {
        try transaction { () throws(DatabaseError) in
            var ids: [RowID] = []
            try run("SELECT id FROM record WHERE zone = ? AND owner = ?", zone.name, zone.owner) { (statement) throws(DatabaseError) in
                if let name = statement.text(at: 0).flatMap(UUID.init(uuidString:)) { ids.append(RowID(name: name, zone: zone)) }
            }
            for id in ids {
                guard resending, let row = try row(id: id), !row.isDeleted, let content = row.ours ?? row.base else {
                    try remove(id: id)
                    continue
                }
                try write(Row(id: id.name, zone: row.zone, type: row.type, ours: content))
            }
        }
    }

    /// The bytes of the sync engine's state, kept in the one row of the `engine_state` table,
    /// or `nil` when none is saved. See `engineState`.
    ///
    /// Neither reading nor writing throws. A state that is lost, or not saved, only makes the
    /// engine fetch changes again, and saving a version this device already has changes nothing.
    var engineStateData: Data? {
        get {
            var data: Data?
            try? run("SELECT data FROM engine_state WHERE id = 0") { (statement) throws(DatabaseError) in data = statement.blob(at: 0) }
            return data
        }
        set {
            if let newValue {
                try? run("INSERT OR REPLACE INTO engine_state (id, data) VALUES (0, ?)", newValue)
            } else {
                try? run("DELETE FROM engine_state")
            }
        }
    }

    /// The schema the record type `name` was last registered with, or `nil` when it has none.
    func storedSchema(named name: String) -> JSONSchema? {
        var text: String?
        try? run("SELECT schema FROM record_schema WHERE name = ?", name) { (statement) throws(DatabaseError) in text = statement.text(at: 0) }
        return text.flatMap { try? JSONDecoder().decode(JSONSchema.self, from: Data($0.utf8)) }
    }

    /// Keeps `schema` as the one the record type `name` was last registered with.
    func store(_ schema: JSONSchema, named name: String) {
        guard let data = try? JSONEncoder().encode(schema) else { return }
        try? run("INSERT OR REPLACE INTO record_schema (name, schema) VALUES (?, ?)", name, String(decoding: data, as: UTF8.self))
    }

    /// Every zone that holds a row, for making sure each exists before its records upload.
    ///
    /// Only a ``Zone/Database/private`` zone can be created by this device. A shared zone
    /// belongs to its owner, and the public zone always exists.
    ///
    /// ```swift
    /// let missing = try container.zones().filter { $0.database == .private }
    /// syncEngine.state.add(pendingDatabaseChanges: missing.map { .saveZone(CKRecordZone(zoneID: $0.zoneID)) })
    /// ```
    func zones() throws(DatabaseError) -> Set<Zone> {
        var zones: Set<Zone> = []
        try run("SELECT DISTINCT zone, owner FROM record") { (statement) throws(DatabaseError) in
            zones.insert(Zone(statement.text(at: 0) ?? "", owner: statement.text(at: 1) ?? ""))
        }
        return zones
    }

    /// The id, zone and kind of every row waiting to upload: a save, or, with `isDeleted`, a delete.
    func pendingRows() throws(DatabaseError) -> [(id: UUID, zone: Zone, isDeleted: Bool)] {
        var rows: [(id: UUID, zone: Zone, isDeleted: Bool)] = []
        try run("""
            SELECT id, zone, owner, is_deleted FROM record
            WHERE theirs IS NULL AND error IS NULL AND (ours IS NOT NULL OR is_deleted = 1)
            """) { (statement) throws(DatabaseError) in
            guard let id = statement.text(at: 0).flatMap(UUID.init(uuidString:)) else { return }
            rows.append((id, Zone(statement.text(at: 1) ?? "", owner: statement.text(at: 2) ?? ""), sqlite3_column_int(statement, 3) != 0))
        }
        return rows
    }

    /// Changes the row for `id` by `change`, in one locked read and write. With no row for
    /// `id`, changes `new` and adds it, or does nothing when `new` is `nil`. Only the sync
    /// engine's work changes a row this way, so the change is logged with ``syncAuthor``.
    func update(id: RowID, inserting new: Row? = nil, _ change: (inout Row) -> Void) throws(DatabaseError) {
        try transaction(author: Self.syncAuthor) { () throws(DatabaseError) in
            guard var row = try row(id: id) ?? new else { return }
            change(&row)
            try write(row)
        }
    }

    /// The `sequence` of the newest `record_change` row ever logged, or 0 when none was.
    func latestChange() throws(DatabaseError) -> Int64 {
        var sequence: Int64 = 0
        try run("SELECT seq FROM sqlite_sequence WHERE name = 'record_change'") { (statement) throws(DatabaseError) in
            sequence = sqlite3_column_int64(statement, 0)
        }
        return sequence
    }

    /// The changes logged after `sequence`, one per transaction in commit order, and the
    /// `sequence` of the newest. When rows after `sequence` were purged before they were
    /// read, the changes are one with `nil` ids, since any row may have changed.
    func loggedChanges(after sequence: Int64) throws(DatabaseError) -> (last: Int64, changes: [Change]) {
        let last = try latestChange()
        guard last > sequence else { return (sequence, []) }
        var first: Int64?
        try run("SELECT MIN(sequence) FROM record_change") { (statement) throws(DatabaseError) in
            if sqlite3_column_type(statement, 0) != SQLITE_NULL { first = sqlite3_column_int64(statement, 0) }
        }
        guard let first, first <= sequence + 1 else { return (last, [(author: nil, ids: nil)]) }
        let changes = try loggedTransactions(after: sequence).filter { $0.id <= last }.map { transaction in
            (author: transaction.author, ids: Set(transaction.changes.map(\.id)))
        }
        return (last, changes)
    }

    /// Stamps every `record_change` row this transaction logged with `author`, and with the
    /// newest row's `sequence` as the transaction's `txn`. Runs just before `COMMIT`.
    func stampChanges(author: String?) throws(DatabaseError) {
        try run("""
            UPDATE record_change SET author = ?, txn = (SELECT seq FROM sqlite_sequence WHERE name = 'record_change')
            WHERE txn IS NULL
            """, author)
    }

    /// Removes the `record_change` rows logged before `date`, an hour ago unless given.
    func purgeChanges(before date: Date = Date(timeIntervalSinceNow: -changeLifetime)) throws(DatabaseError) {
        try run("DELETE FROM record_change WHERE timestamp < ?", date.timeIntervalSince1970)
    }

    /// The `record_change` rows logged after `sequence`, grouped into their transactions,
    /// oldest first.
    func loggedTransactions(after sequence: Int64) throws(DatabaseError) -> [RecordTransaction] {
        var transactions: [RecordTransaction] = []
        var current: (id: Int64, author: String?, timestamp: Date, changes: [RecordTransaction.Change])?
        try run("""
            SELECT COALESCE(txn, sequence), author, timestamp, id, zone, owner, type, kind FROM record_change
            WHERE sequence > ? ORDER BY sequence
            """, sequence) { (statement) throws(DatabaseError) in
            guard let name = statement.text(at: 3).flatMap(UUID.init(uuidString:)) else { return }
            let txn = sqlite3_column_int64(statement, 0)
            if current?.id != txn {
                if let current { transactions.append(RecordTransaction(id: current.id, author: current.author, timestamp: current.timestamp, changes: current.changes)) }
                current = (txn, statement.text(at: 1), Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), [])
            }
            let id = RowID(name: name, zone: Zone(statement.text(at: 4) ?? "", owner: statement.text(at: 5) ?? ""))
            let type = statement.text(at: 6) ?? ""
            switch statement.text(at: 7) {
            case "insert": current?.changes.append(.inserted(id, type: type))
            case "update": current?.changes.append(.updated(id, type: type))
            default: current?.changes.append(.deleted(id, type: type))
            }
        }
        if let current { transactions.append(RecordTransaction(id: current.id, author: current.author, timestamp: current.timestamp, changes: current.changes)) }
        return transactions
    }

    /// The row for `id`, or `nil` when the container has none.
    func row(id: RowID) throws(DatabaseError) -> Row? {
        var row: Row?
        try run("""
            SELECT type, metadata, base, ours, theirs, sent, is_deleted, error FROM record
            WHERE id = ? AND zone = ? AND owner = ?
            """, id.name.uuidString, id.zone.name, id.zone.owner) { (statement) throws(DatabaseError) in
            row = Row(
                id: id.name,
                zone: id.zone,
                type: statement.text(at: 0) ?? "",
                metadata: statement.blob(at: 1),
                base: try statement.json(at: 2).map { resolved($0, id: id) },
                ours: try statement.json(at: 3).map { resolved($0, id: id) },
                theirs: try statement.json(at: 4).map { resolved($0, id: id) },
                sent: try statement.json(at: 5).map { resolved($0, id: id) },
                isDeleted: sqlite3_column_int(statement, 6) != 0,
                error: statement.text(at: 7)
            )
        }
        return row
    }
}

extension RecordContainer {
    /// The transactions committed after the one `id`, or every one kept when `id` is `nil`,
    /// oldest first, from this app and anything else sharing its database, such as a widget.
    ///
    /// Transactions are kept for an hour, so one older than that may be gone. Keep the last
    /// `id` you read and pass it next time.
    ///
    /// ```swift
    /// let recent = try container.transactions(after: lastSeen)
    /// lastSeen = recent.last?.id ?? lastSeen
    /// ```
    public func transactions(after id: RecordTransaction.ID? = nil) throws(DatabaseError) -> [RecordTransaction] {
        try loggedTransactions(after: id ?? 0)
    }

    /// Removes the transaction `id` and every one before it, as once they are read.
    ///
    /// ```swift
    /// .onChange(of: scenePhase) { _, phase in
    ///     if phase == .background, let last { try? container.deleteTransactions(through: last) }
    /// }
    /// ```
    public func deleteTransactions(through id: RecordTransaction.ID) throws(DatabaseError) {
        try run("DELETE FROM record_change WHERE COALESCE(txn, sequence) <= ?", id)
    }
}

private extension RecordContainer {
    /// `json` as the text the table stores.
    static func text(_ json: JSONRepresentation) throws(DatabaseError) -> String {
        do {
            return String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        } catch {
            throw DatabaseError(code: SQLITE_MISMATCH, description: "JSON could not be stored: \(error)")
        }
    }

    /// Removes the row for `id`.
    func remove(id: RowID) throws(DatabaseError) {
        try run("DELETE FROM record WHERE id = ? AND zone = ? AND owner = ?", id.name.uuidString, id.zone.name, id.zone.owner)
        sweepAssets(id: id)
    }

    /// Writes every column of `row`, replacing any row with the same id.
    func write(_ row: Row) throws(DatabaseError) {
        let text = { (json: JSONRepresentation?) throws(DatabaseError) -> String? in
            try json.map { (json) throws(DatabaseError) in try Self.text(self.portable(json, id: row.rowID)) }
        }
        try run("""
            INSERT OR REPLACE INTO record (id, zone, owner, type, metadata, base, ours, theirs, sent, is_deleted, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, row.id.uuidString, row.zone.name, row.zone.owner, row.type, row.metadata,
            try text(row.base), try text(row.ours), try text(row.theirs), try text(row.sent),
            row.isDeleted, row.error)
        sweepAssets(of: row)
    }

    /// Prepares `sql`, binds `values` in order, and steps through it, passing each result row to `body`.
    func run(_ sql: String, _ values: Any?..., each body: (OpaquePointer) throws(DatabaseError) -> Void = { _ in }) throws(DatabaseError) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(code: sqlite3_errcode(connection), connection: connection)
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT: SQLite copies the bytes before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in zip(Int32(1)..., values) {
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, transient)
            case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case let flag as Bool: sqlite3_bind_int(statement, index, flag ? 1 : 0)
            case let number as Int64: sqlite3_bind_int64(statement, index, number)
            case let number as Double: sqlite3_bind_double(statement, index, number)
            default: sqlite3_bind_null(statement, index)
            }
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(statement)
            case SQLITE_DONE: return
            case let code: throw DatabaseError(code: code, connection: connection)
            }
        }
    }
}

private extension OpaquePointer {
    func text(at column: Int32) -> String? {
        sqlite3_column_text(self, column).map { String(cString: $0) }
    }

    /// The bytes in `column`, empty for an empty blob, which SQLite returns as a null pointer.
    func blob(at column: Int32) -> Data? {
        guard sqlite3_column_type(self, column) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(self, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(self, column)))
    }

    func json(at column: Int32) throws(DatabaseError) -> JSONRepresentation? {
        guard let text = text(at: column) else { return nil }
        do {
            return try JSONDecoder().decode(JSONRepresentation.self, from: Data(text.utf8))
        } catch {
            throw DatabaseError(code: SQLITE_CORRUPT, description: "Stored JSON could not be read: \(error)")
        }
    }
}
