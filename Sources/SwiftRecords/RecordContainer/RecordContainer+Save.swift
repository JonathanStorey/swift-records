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
        CREATE INDEX IF NOT EXISTS record_type ON record (type, zone, owner);
        CREATE TABLE IF NOT EXISTS record_schema (
            name TEXT PRIMARY KEY NOT NULL,
            schema TEXT NOT NULL
        )
        """

    /// Saves `record` as this device's version: `ours`, waiting to upload.
    ///
    /// The row's id comes from the value at `id`, by ``recordName(for:type:)``, and `zone`,
    /// so the same record saved to another zone is another row. A new id adds a row. An
    /// existing one replaces `ours`, clears `isDeleted` and `error`, and keeps
    /// `base`, `theirs`, `metadata` and the zone, in one statement. Each `@Asset` file is
    /// copied into the container, so the row keeps it however the original changes. Asserts that a record
    /// saved to ``Zone/public`` has no `@Encrypted` values, which the public database rejects.
    ///
    /// Each reference with no zone is placed in `zone`, and one in another zone throws,
    /// since CloudKit follows a reference only within its record's zone. Each
    /// `@References(inverse:)` list is left out of the record and saved as ``Relationship``
    /// records instead, in the same transaction, as ``relationshipChanges(_:of:type:zone:)``
    /// describes.
    ///
    /// ```swift
    /// try container.save(our: page, id: \.slug, zone: "Pages")
    /// ```
    func save<Record: Encodable, ID: Encodable>(our record: Record, id: KeyPath<Record, ID>, zone: Zone) throws {
        assert(zone != .public || !Mirror(reflecting: record).properties.contains { $0.value is any EncryptedValue },
               "The public database cannot store @Encrypted values, so \(Record.self) cannot be saved to Zone.public.")
        let type = Self.recordType(of: Record.self)
        let id = RowID(name: try Self.recordName(for: record[keyPath: id], type: type), zone: zone)
        var json = try JSONRepresentation(record)
        let lists = try json.removeRelationshipLists()
        let ours = try Self.text(portable(storingAssets(of: record, in: json.placingReferences(in: zone), id: id), id: id))
        let changes = try relationshipChanges(lists, of: id.name, type: type, zone: zone)
        let relationshipType = Self.recordType(of: Relationship.self)
        let saved = try changes.saved.map { relationship in
            (id: RowID(name: relationship.id, zone: zone), ours: try Self.text(JSONRepresentation(relationship).placingReferences(in: zone)))
        }
        try transaction { () throws(DatabaseError) in
            try write(ours: ours, id: id, type: type)
            for relationship in saved { try write(ours: relationship.ours, id: relationship.id, type: relationshipType) }
            for relationship in changes.deleted { try delete(id: RowID(name: relationship.id, zone: zone)) }
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
    func save(their json: JSONRepresentation, id: String, zone: Zone, type: String, metadata: Data?) throws(DatabaseError) {
        // Looked up before the row is locked, since the lookup takes the same lock.
        let registered = Result { try registeredType(named: type) }, side = favoring
        let rowID = RowID(name: id, zone: zone)
        try update(id: rowID, inserting: Row(id: id, zone: zone, type: type)) { row in
            row.metadata = metadata
            row.receive(json) { ours, theirs, base in
                try merged(ours, with: theirs, from: base, as: registered.get(), id: rowID, favoring: side)
            }
        }
    }

    /// Deletes `record` in `zone` on this device, identified by the value at `id`, as
    /// ``delete(id:)`` describes, together with every ``Relationship`` it is a side of, in
    /// one transaction. A copy of the record in another zone stays.
    ///
    /// ```swift
    /// try container.delete(our: page, id: \.slug, zone: "Pages")
    /// ```
    func delete<Record: Encodable, ID: Encodable>(our record: Record, id: KeyPath<Record, ID>, zone: Zone) throws {
        let type = Self.recordType(of: Record.self)
        let id = RowID(name: try Self.recordName(for: record[keyPath: id], type: type), zone: zone)
        let relationships = Record.self == Relationship.self ? [] : try relationships(of: id.name, type: type, in: zone)
        try transaction { () throws(DatabaseError) in
            try delete(id: id)
            for relationship in relationships { try delete(id: RowID(name: relationship.id, zone: zone)) }
        }
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
            guard row.metadata != nil || row.base != nil else { return try remove(id: id, type: row.type) }
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
            guard let ours = row.ours, !row.isDeleted else { return try remove(id: id, type: row.type) }
            try write(Row(id: id.name, zone: row.zone, type: row.type, ours: ours))
        }
    }

    /// Removes every row on this device, and the engine's state, sending nothing, as when the
    /// iCloud account signs out or changes. Unlike ``delete(id:)``, nothing is deleted on the server.
    func clear() throws(DatabaseError) {
        try transaction { () throws(DatabaseError) in
            try run("SELECT id, zone, owner, type FROM record") { (statement) throws(DatabaseError) in
                guard let name = statement.text(at: 0) else { return }
                log(.deleted(RowID(name: name, zone: Zone(statement.text(at: 1) ?? "", owner: statement.text(at: 2) ?? "")), type: statement.text(at: 3) ?? ""))
            }
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
            var ids: [(id: RowID, type: String)] = []
            try run("SELECT id, type FROM record WHERE zone = ? AND owner = ?", zone.name, zone.owner) { (statement) throws(DatabaseError) in
                if let name = statement.text(at: 0) { ids.append((RowID(name: name, zone: zone), statement.text(at: 1) ?? "")) }
            }
            for (id, type) in ids {
                guard resending, let row = try row(id: id), !row.isDeleted, let content = row.ours ?? row.base else {
                    try remove(id: id, type: type)
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
    func pendingRows() throws(DatabaseError) -> [(id: String, zone: Zone, isDeleted: Bool)] {
        var rows: [(id: String, zone: Zone, isDeleted: Bool)] = []
        try run("""
            SELECT id, zone, owner, is_deleted FROM record
            WHERE theirs IS NULL AND error IS NULL AND (ours IS NOT NULL OR is_deleted = 1)
            """) { (statement) throws(DatabaseError) in
            guard let id = statement.text(at: 0) else { return }
            rows.append((id, Zone(statement.text(at: 1) ?? "", owner: statement.text(at: 2) ?? ""), sqlite3_column_int(statement, 3) != 0))
        }
        return rows
    }

    /// Changes the row for `id` by `change`, in one locked read and write. With no row for
    /// `id`, changes `new` and adds it, or does nothing when `new` is `nil`. Only the sync
    /// engine's work changes a row this way, so the change is logged with ``syncAuthor``.
    func update(id: RowID, inserting new: Row? = nil, _ change: (inout Row) -> Void) throws(DatabaseError) {
        try transaction(author: Self.syncAuthor) { () throws(DatabaseError) in
            let existing = try row(id: id)
            guard var row = existing ?? new else { return }
            change(&row)
            try write(row, isNew: existing == nil)
        }
    }

    /// The saved value of every `T` in `zone` that `predicate` accepts, sorted by `order`.
    ///
    /// Each row's value is this device's version, `ours`, or else the server's, `base`. Rows
    /// marked deleted are left out, and so is a row whose value does not decode as `T`, such
    /// as one a newer version of the app wrote. The part of `predicate` SQLite can test, by
    /// ``filter(for:)``, narrows the rows first, and each row left is decoded and tested as
    /// SQLite reads it, so only the matches are kept in memory. With no `order`, the values
    /// keep no particular order. Each `@References(inverse:)` list is filled from the zone's
    /// ``Relationship`` records before its record decodes, so `predicate` can test it.
    ///
    /// ```swift
    /// let drafts = try container.fetch(Note.self, in: "Notes", predicate: #Predicate { $0.isDraft }, order: [SortDescriptor(\.title)])
    /// ```
    func fetch<T: Decodable>(_ type: T.Type, in zone: Zone, predicate: Predicate<T>? = nil, order: [SortDescriptor<T>] = []) throws -> [T] {
        try fetch(type, in: zone, where: predicate.flatMap(Self.filter(for:)), predicate: predicate, order: order)
    }

    /// The saved value of every `T` in `zone` whose row `filter` keeps and `predicate`
    /// accepts, sorted by `order`. `filter` only narrows the rows that decode, so it must
    /// keep every row that `predicate` accepts.
    func fetch<T: Decodable>(_ type: T.Type, in zone: Zone, where filter: SQLFilter?, predicate: Predicate<T>? = nil, order: [SortDescriptor<T>] = []) throws -> [T] {
        var values: [T] = []
        var failure: (any Error)?
        let recordType = Self.recordType(of: type)
        let lists = type == Relationship.self ? [:] : try relationshipLists(in: zone, type: recordType, where: filter)
        try run("""
            SELECT id, COALESCE(ours, base) FROM record
            WHERE type = ? AND zone = ? AND owner = ? AND is_deleted = 0 AND \(filter?.clause ?? "1")
            """, values: [recordType, zone.name, zone.owner] + (filter?.values ?? [])) { (statement) throws(DatabaseError) in
            guard failure == nil,
                  let name = statement.text(at: 0),
                  let json = (try? statement.json(at: 1))??.relating(lists[name]),
                  let value = try? resolved(json, id: RowID(name: name, zone: zone)).decode(type) else { return }
            do {
                if try predicate?.evaluate(value) ?? true { values.append(value) }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return order.isEmpty ? values : values.sorted(using: order)
    }

    /// The saved value of the row `id` as `type`, its `ours ?? base` with its relationship
    /// lists filled, or `nil` when there is no such row, it is deleted, or it does not decode.
    func fetch<T: Decodable>(_ type: T.Type, id: RowID) throws -> T? {
        try fetch(type, in: id.zone, where: (clause: "id = ?", values: [id.name], isExact: true)).first
    }

    /// The connection's `PRAGMA data_version`, which changes only when another connection
    /// commits to the file, or 0 when it cannot be read.
    func currentDataVersion() -> Int64 {
        var version: Int64 = 0
        try? run("PRAGMA data_version") { (statement) throws(DatabaseError) in version = sqlite3_column_int64(statement, 0) }
        return version
    }

    /// Whether the container has a row for `id`.
    func contains(_ id: RowID) throws(DatabaseError) -> Bool {
        var found = false
        try run("SELECT 1 FROM record WHERE id = ? AND zone = ? AND owner = ?", id.name, id.zone.name, id.zone.owner) { _ in found = true }
        return found
    }

    /// The row for `id`, or `nil` when the container has none.
    func row(id: RowID) throws(DatabaseError) -> Row? {
        var row: Row?
        try run("""
            SELECT type, metadata, base, ours, theirs, sent, is_deleted, error FROM record
            WHERE id = ? AND zone = ? AND owner = ?
            """, id.name, id.zone.name, id.zone.owner) { (statement) throws(DatabaseError) in
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

private extension RecordContainer {
    /// `json` as the text the table stores.
    static func text(_ json: JSONRepresentation) throws(DatabaseError) -> String {
        do {
            return String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        } catch {
            throw DatabaseError(code: SQLITE_MISMATCH, description: "JSON could not be stored: \(error)")
        }
    }

    /// Removes the row for `id`, a record of the record type `type`.
    func remove(id: RowID, type: String) throws(DatabaseError) {
        let relationship = type == Self.recordType(of: Relationship.self) ? try row(id: id).flatMap { $0.ours ?? $0.base } : nil
        log(.deleted(id, type: type), relating: relationship)
        try run("DELETE FROM record WHERE id = ? AND zone = ? AND owner = ?", id.name, id.zone.name, id.zone.owner)
        sweepAssets(id: id)
    }

    /// Writes every column of `row`, replacing any row with the same id, which `isNew` says
    /// there is none of. A row marked deleted is logged as deleted.
    func write(_ row: Row, isNew: Bool = false) throws(DatabaseError) {
        let relationship = row.type == Self.recordType(of: Relationship.self) ? row.ours ?? row.base ?? row.theirs : nil
        log(row.isDeleted ? .deleted(row.rowID, type: row.type) : isNew ? .inserted(row.rowID, type: row.type) : .updated(row.rowID, type: row.type), relating: relationship)
        let text = { (json: JSONRepresentation?) throws(DatabaseError) -> String? in
            try json.map { (json) throws(DatabaseError) in try Self.text(self.portable(json, id: row.rowID)) }
        }
        try run("""
            INSERT OR REPLACE INTO record (id, zone, owner, type, metadata, base, ours, theirs, sent, is_deleted, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, row.id, row.zone.name, row.zone.owner, row.type, row.metadata,
            try text(row.base), try text(row.ours), try text(row.theirs), try text(row.sent),
            row.isDeleted, row.error)
        sweepAssets(of: row)
    }

    /// Prepares `sql`, binds `values` in order, and steps through it, passing each result row to `body`.
    func run(_ sql: String, _ values: Any?..., each body: (OpaquePointer) throws(DatabaseError) -> Void = { _ in }) throws(DatabaseError) {
        try run(sql, values: values, each: body)
    }

    /// Prepares `sql`, binds `values` in order, and steps through it, passing each result row to `body`.
    func run(_ sql: String, values: [Any?], each body: (OpaquePointer) throws(DatabaseError) -> Void) throws(DatabaseError) {
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
            case let integer as Int64: sqlite3_bind_int64(statement, index, integer)
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

private extension RecordContainer {
    /// Writes `ours` as the row `id`'s version, adding the row when it is new, in one
    /// statement, and logs the change.
    func write(ours: String, id: RowID, type: String) throws(DatabaseError) {
        let relationship = type == Self.recordType(of: Relationship.self) ? try? JSONDecoder().decode(JSONRepresentation.self, from: Data(ours.utf8)) : nil
        log(try contains(id) ? .updated(id, type: type) : .inserted(id, type: type), relating: relationship)
        try run("""
            INSERT INTO record (id, zone, owner, type, ours) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (id, zone, owner) DO UPDATE SET type = excluded.type, ours = excluded.ours, is_deleted = 0, error = NULL
            """, id.name, id.zone.name, id.zone.owner, type, ours)
        if let row = try row(id: id) { sweepAssets(of: row) }
    }
}
