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

    /// Saves `record` as this device's version in the row `id`: `ours`, waiting to upload.
    ///
    /// A new row is added. An existing one replaces `ours`, clears `isDeleted` and `error`,
    /// and keeps `base`, `theirs` and `metadata`, in one statement. The row's name is checked
    /// against CloudKit's 255 characters. Each `@Asset` file is copied into the container, so
    /// the row keeps it however the original changes. Asserts that a record saved to
    /// ``Zone/public`` has no `@Encrypted` values, which the public database rejects.
    ///
    /// Each reference with no zone is placed in the row's zone, and one in another zone
    /// throws, since CloudKit follows a reference only within its record's zone. Each
    /// `@References(inverse:)` list is left out of the record and saved as ``Relationship``
    /// records instead, in the same transaction, as ``relationshipChanges(_:of:type:zone:)``
    /// describes.
    ///
    /// ```swift
    /// try container.save(our: page, at: RecordContainer.RowID(Page.self, id: page.slug, zone: "Pages"))
    /// ```
    func save<Record: Encodable>(our record: Record, at id: RowID) throws(RecordError) {
        let type = Self.recordType(of: Record.self), zone = id.zone
        assert(zone != .public || !Mirror(reflecting: record).properties.contains { $0.value is any EncryptedValue },
               "The public database cannot store @Encrypted values, so \(Record.self) cannot be saved to Zone.public.")
        guard id.name.utf8.count <= 255 else { throw .nameTooLong(name: id.name) }
        // Locked from the first read, so the relationships compared are the ones replaced.
        try locked { () throws(RecordError) in
            do {
                var json = try JSONRepresentation(record)
                let lists = try json.removeRelationshipLists()
                let ours = try Self.text(portable(storingAssets(of: record, in: json.placingReferences(in: zone), id: id), id: id))
                let changes = try relationshipChanges(lists, of: id.name, type: type, zone: zone)
                let saved = try changes.saved.map { relationship in
                    (id: RowID(name: relationship.id, zone: zone), ours: try Self.text(JSONRepresentation(relationship).placingReferences(in: zone)))
                }
                try transaction { () throws(DatabaseError) in
                    try write(ours: ours, id: id, type: type)
                    for relationship in saved { try write(ours: relationship.ours, id: relationship.id, type: Self.relationshipType) }
                    for relationship in changes.deleted { try delete(id: RowID(name: relationship.id, zone: zone)) }
                }
            } catch {
                throw RecordError(error, type: type)
            }
        }
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

    /// Deletes the row `id` of a record of type `type` on this device, as ``delete(id:)``
    /// describes, together with every ``Relationship`` it is a side of, in one transaction. A
    /// copy of the record in another zone stays.
    func delete(_ id: RowID, type: String) throws(RecordError) {
        let zone = id.zone
        // Locked from the first read, so every relationship deleted is one there now.
        try locked { () throws(RecordError) in
            do {
                let relationships = type == Self.relationshipType ? [] : try relationships(of: id.name, type: type, in: zone)
                try transaction { () throws(DatabaseError) in
                    try delete(id: id)
                    for relationship in relationships { try delete(id: RowID(name: relationship.id, zone: zone)) }
                }
            } catch {
                throw RecordError(error, type: type)
            }
        }
    }

    /// Deletes the record `id` on this device.
    ///
    /// A record the server has never confirmed is removed at once, since there is nothing
    /// to delete there. Any other record waits to upload its delete, and its unsent changes,
    /// any version waiting to merge, and any error are dropped. Saving the record again
    /// before the delete uploads undoes it.
    func delete(id: RowID) throws(DatabaseError) {
        try transaction { () throws(DatabaseError) in
            guard let previous = try row(id: id) else { return }
            guard previous.metadata != nil || previous.base != nil else { return try remove(id: id, type: previous.type) }
            var row = previous
            row.isDeleted = true
            row.ours = .none
            row.theirs = .none
            row.error = nil
            try write(row, replacing: previous)
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
            try write(Row(id: id.name, zone: row.zone, type: row.type, ours: ours), replacing: row)
        }
    }

    /// Removes every row on this device, and the engine's state, sending nothing, as when the
    /// iCloud account signs out or changes. Unlike ``delete(id:)``, nothing is deleted on the server.
    func clear() throws(DatabaseError) {
        try transaction(author: Self.syncAuthor) { () throws(DatabaseError) in
            try run("SELECT id, zone, owner, type FROM record") { (statement) throws(DatabaseError) in
                guard let name = statement.text(at: 0) else { return }
                log(.deleted(RowID(name: name, zone: Zone(statement.text(at: 1) ?? "", owner: statement.text(at: 2) ?? "")), type: statement.text(at: 3) ?? ""))
            }
            try run("DELETE FROM record")
            try run("DELETE FROM engine_state")
        }
        // Only once the rows are gone for good, so a failed commit keeps its files.
        try? FileManager.default.removeItem(at: assets)
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
        try transaction(author: Self.syncAuthor) { () throws(DatabaseError) in
            var ids: [(id: RowID, type: String)] = []
            try run("SELECT id, type FROM record WHERE zone = ? AND owner = ?", zone.name, zone.owner) { (statement) throws(DatabaseError) in
                if let name = statement.text(at: 0) { ids.append((RowID(name: name, zone: zone), statement.text(at: 1) ?? "")) }
            }
            for (id, type) in ids {
                guard resending, let row = try row(id: id), !row.isDeleted, let content = row.ours ?? row.base else {
                    try remove(id: id, type: type)
                    continue
                }
                try write(Row(id: id.name, zone: row.zone, type: row.type, ours: content), replacing: row)
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
            locked {
                if let newValue {
                    try? run("INSERT OR REPLACE INTO engine_state (id, data) VALUES (0, ?)", newValue)
                } else {
                    try? run("DELETE FROM engine_state")
                }
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
        locked { try? run("INSERT OR REPLACE INTO record_schema (name, schema) VALUES (?, ?)", name, String(decoding: data, as: UTF8.self)) }
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
            try write(row, replacing: existing, isBookkeeping: true)
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
        let values = try fetch(type, in: zone, where: predicate.flatMap(Self.filter(for:)), predicate: predicate)
        return order.isEmpty ? values : values.sorted(using: order)
    }

    /// The saved value of every `T` in `zone` whose row `filter` keeps and `predicate`
    /// accepts, in the order of `order`, an `ORDER BY` clause and its values, skipping the
    /// first `offset` matches and stopping after `limit`. `filter` only narrows the rows that
    /// decode, so it must keep every row that `predicate` accepts.
    ///
    /// Rows arrive in order and are decoded one at a time, so decoding stops once the offset
    /// and limit are filled. Every other fetch reads through here, or, when SQLite does all
    /// of the work, through the same ``select(where:orderBy:)`` and ``value(of:json:in:lists:)``.
    func fetch<T: Decodable>(_ type: T.Type, in zone: Zone, where filter: SQLFilter?, predicate: Predicate<T>? = nil, orderBy order: SQLOrder? = nil, offset: Int = 0, limit: Int? = nil) throws -> [T] {
        let recordType = Self.recordType(of: type)
        let lists = recordType == Self.relationshipType ? [:] : try relationshipLists(in: zone, type: recordType, where: filter)
        var found: [T] = [], skipped = 0, failure: (any Error)?
        try run(select(where: filter, orderBy: order), values: [recordType, zone.name, zone.owner] + (filter?.values ?? []) + (order?.values ?? [])) { (statement) throws(DatabaseError) in
            guard failure == nil, found.count < limit ?? .max,
                  let name = statement.text(at: 0), let json = (try? statement.json(at: 1)) ?? nil,
                  let value: T = value(of: name, json: json, in: zone, lists: lists) else { return }
            do {
                guard try predicate?.evaluate(value) ?? true else { return }
            } catch {
                failure = error
                return
            }
            if skipped < offset { skipped += 1 } else { found.append(value) }
        }
        if let failure { throw failure }
        return found
    }

    /// The saved records `descriptor` describes in `zone`, leaving out the rows named in
    /// `excluded`, such as the ones a context has open.
    ///
    /// The work depends on how much SQL can do:
    /// - When the predicate translates exactly and every sort translates, SQLite filters,
    ///   sorts, skips the offset and stops at the limit, and only the rows returned are read
    ///   and decoded, with only their relationship lists.
    /// - When the sort translates but the predicate does not fully, rows arrive in order and
    ///   stop being decoded once the offset and limit are filled.
    /// - Otherwise every match is decoded and sorted in Swift.
    ///
    /// Ties are broken by record name in SQL, so the order is the same every time. A row that
    /// does not decode is skipped, so a limited fetch can return fewer than its limit.
    func fetch<T: Codable>(_ descriptor: RecordDescriptor<T>, in zone: Zone, excluding excluded: [String] = []) throws -> [T] {
        let predicate = descriptor.predicate
        let filter = Self.filter(for: predicate, excluding: excluded)
        let offset = descriptor.offset, limit = descriptor.limit
        guard let order = descriptor.sortBy.isEmpty ? (clause: "", values: []) : Self.orderBy(descriptor.sortBy) else {
            // No SQL sort: every match, sorted in Swift.
            let all = try fetch(T.self, in: zone, where: filter, predicate: predicate).sorted(using: descriptor.sortBy)
            return Array(all.dropFirst(offset).prefix(limit ?? .max))
        }
        guard filter.isExact else {
            return try fetch(T.self, in: zone, where: filter, predicate: predicate, orderBy: order, offset: offset, limit: limit)
        }
        // SQLite does all of it, so only the rows returned are read, with only their lists.
        let recordType = Self.recordType(of: T.self)
        var rows: [(name: String, json: JSONRepresentation)] = []
        try run(select(where: filter, orderBy: order) + " LIMIT ? OFFSET ?", values: [recordType, zone.name, zone.owner] + filter.values + order.values + [limit ?? -1, offset]) { (statement) throws(DatabaseError) in
            guard let name = statement.text(at: 0), let json = (try? statement.json(at: 1)) ?? nil else { return }
            rows.append((name, json))
        }
        let names = JSONRepresentation.array(rows.map { .string($0.name) }).description
        let lists = recordType == Self.relationshipType ? [:]
            : try relationshipLists(in: zone, type: recordType, where: ("id IN (SELECT value FROM json_each(?))", [names], true))
        return rows.compactMap { value(of: $0.name, json: $0.json, in: zone, lists: lists) }
    }

    /// How many records `fetch(_:in:excluding:)` would return, counted by SQLite when the
    /// predicate translates exactly, so nothing is read or decoded. A row that does not decode
    /// is still counted then.
    func fetchCount<T: Codable>(_ descriptor: RecordDescriptor<T>, in zone: Zone, excluding excluded: [String] = []) throws -> Int {
        let filter = Self.filter(for: descriptor.predicate, excluding: excluded)
        guard filter.isExact else {
            return descriptor.count(ofPageIn: try fetch(T.self, in: zone, where: filter, predicate: descriptor.predicate).count)
        }
        var count = 0
        try run("SELECT COUNT(*) FROM (\(select(where: filter)))", values: [Self.recordType(of: T.self), zone.name, zone.owner] + filter.values) { (statement) throws(DatabaseError) in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return descriptor.count(ofPageIn: count)
    }

    /// The rows `predicate` keeps, in SQL as far as it translates, leaving out the rows
    /// named in `excluded`.
    private static func filter<T: Decodable>(for predicate: Predicate<T>?, excluding excluded: [String]) -> SQLFilter {
        let narrowing = predicate.flatMap(Self.filter(for:))
        var filter: SQLFilter = (narrowing?.clause ?? "1", narrowing?.values ?? [], predicate == nil || narrowing?.isExact == true)
        if !excluded.isEmpty {
            filter.clause += " AND id NOT IN (SELECT value FROM json_each(?))"
            filter.values.append(JSONRepresentation.array(excluded.map(JSONRepresentation.string)).description)
        }
        return filter
    }

    /// The query for each live row's name and saved value, of one type in one zone, that
    /// `filter` keeps, in the order of `order` and then by name. Its values are the type, the
    /// zone's name and owner, then `filter`'s and `order`'s.
    private func select(where filter: SQLFilter?, orderBy order: SQLOrder? = nil) -> String {
        let sort = order.map { "\n ORDER BY " + ($0.clause.isEmpty ? "" : $0.clause + ", ") + "id" } ?? ""
        return """
            SELECT id, COALESCE(ours, base) FROM record
            WHERE type = ? AND zone = ? AND owner = ? AND is_deleted = 0 AND \(filter?.clause ?? "1")
            """ + sort
    }

    /// The saved value `json` of the row `name` in `zone` as `T`, with its relationship lists
    /// from `lists` and its asset paths resolved, or `nil` when it does not decode.
    private func value<T: Decodable>(of name: String, json: JSONRepresentation, in zone: Zone, lists: [String: [String: RelationshipList]]) -> T? {
        try? resolved(json.relating(lists[name]), id: RowID(name: name, zone: zone)).decode(T.self)
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
        // On the writing connection, where only another process's commit moves it.
        try? run("PRAGMA data_version", on: connection) { (statement) throws(DatabaseError) in version = sqlite3_column_int64(statement, 0) }
        return version
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
        let relationship = type == Self.relationshipType ? try row(id: id)?.content : nil
        log(.deleted(id, type: type), relating: relationship)
        try run("DELETE FROM record WHERE id = ? AND zone = ? AND owner = ?", id.name, id.zone.name, id.zone.owner)
        sweepAssets(id: id)
    }

    /// Writes every column of `row`, replacing `previous`, the row with the same id, if any.
    ///
    /// The write is logged by its kind. Sync bookkeeping, a write of only `metadata`, `sent`,
    /// `theirs` or `error`, is not, unless it changed what a fetch reads, since no reader
    /// sees it, and every upload would otherwise refresh every view.
    func write(_ row: Row, replacing previous: Row?, isBookkeeping: Bool = false) throws(DatabaseError) {
        if !isBookkeeping || previous?.visible != row.visible {
            let change: RecordTransaction.Change = row.isDeleted ? .deleted(row.rowID, type: row.type) : previous == nil ? .inserted(row.rowID, type: row.type) : .updated(row.rowID, type: row.type)
            log(change, relating: row.type == Self.relationshipType ? row.content : nil)
        }
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

    /// Prepares `sql`, binds `values` in order, and steps through it, passing each result row
    /// to `body`: on the read-only connection outside the lock, so it reads the last commit
    /// without waiting, or else on the writing connection under the lock, as every write and
    /// every read inside a transaction must.
    func run(_ sql: String, values: [Any?], each body: (OpaquePointer) throws(DatabaseError) -> Void) throws(DatabaseError) {
        if !holdsLock, let reader { return try run(sql, values: values, on: reader, each: body) }
        try locked { () throws(DatabaseError) in try run(sql, values: values, on: connection, each: body) }
    }

    /// Prepares `sql` on `connection`, binds `values` in order, and steps through it, passing
    /// each result row to `body`.
    func run(_ sql: String, _ values: Any?..., on connection: OpaquePointer, each body: (OpaquePointer) throws(DatabaseError) -> Void = { _ in }) throws(DatabaseError) {
        try run(sql, values: values, on: connection, each: body)
    }

    /// Prepares `sql` on `connection`, binds `values` in order, and steps through it, passing
    /// each result row to `body`.
    func run(_ sql: String, values: [Any?], on connection: OpaquePointer, each body: (OpaquePointer) throws(DatabaseError) -> Void) throws(DatabaseError) {
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
            case let integer as Int: sqlite3_bind_int64(statement, index, Int64(integer))
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
        var exists = false
        try run("SELECT 1 FROM record WHERE id = ? AND zone = ? AND owner = ?", id.name, id.zone.name, id.zone.owner) { _ in exists = true }
        let relationship = type == Self.relationshipType ? try? JSONDecoder().decode(JSONRepresentation.self, from: Data(ours.utf8)) : nil
        log(exists ? .updated(id, type: type) : .inserted(id, type: type), relating: relationship)
        try run("""
            INSERT INTO record (id, zone, owner, type, ours) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (id, zone, owner) DO UPDATE SET type = excluded.type, ours = excluded.ours, is_deleted = 0, error = NULL
            """, id.name, id.zone.name, id.zone.owner, type, ours)
        if let row = try row(id: id) { sweepAssets(of: row) }
    }
}
