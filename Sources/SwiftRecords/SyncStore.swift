import Foundation

/// A field value in the package's own terms, so values can be compared, merged and kept with a snapshot.
enum SyncValue: Hashable, Codable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case uuid(UUID)
    case url(URL)
    case ids([UUID])
    case reference(UUID, ReferenceAction)

    /// A value from a provider's `SyncRecord`, or `nil` for a type fields can't hold.
    init?(fieldValue value: any Sendable) {
        switch value {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Int64: self = .int(value)
        case let value as Int: self = .int(Int64(value))
        case let value as Double: self = .double(value)
        case let value as Date: self = .date(value)
        case let value as Data: self = .data(value)
        case let value as UUID: self = .uuid(value)
        case let value as URL: self = .url(value)
        case let value as [UUID]: self = .ids(value)
        case let value as SyncReference: self = .reference(value.id, value.action)
        default: return nil
        }
    }

    /// The value as a provider sees it.
    var fieldValue: any Sendable {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .date(let value): value
        case .data(let value): value
        case .uuid(let value): value
        case .url(let value): value
        case .ids(let value): value
        case .reference(let id, let action): SyncReference(id: id, action: action)
        }
    }

    /// A decoded property value. Scalars keep their type, and anything else becomes JSON. `nil` for an
    /// optional that holds nothing.
    init?(property value: Any) throws {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return nil }
            try self.init(property: wrapped)
            return
        }
        switch value {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Date: self = .date(value)
        case let value as Data: self = .data(value)
        case let value as UUID: self = .uuid(value)
        case let value as URL: self = .url(value)
        case let value as Double: self = .double(value)
        case let value as Float: self = .double(Double(value))
        case let value as any BinaryInteger:
            // Above `Int64.max`, as stored: text.
            self = Int64(exactly: value).map { .int($0) } ?? .string(String(value))
        case let value as any Encodable: self = .data(try CanonicalJSON.encode(value))
        default: return nil
        }
    }

    /// The value as SQLite would hold it, before it is converted to its property's type.
    var sqliteValue: SQLiteValue {
        get throws {
            switch self {
            case .string(let value): .text(value)
            case .int(let value): .integer(value)
            case .double(let value): .real(value)
            case .bool(let value): .integer(value ? 1 : 0)
            case .date(let value): try ValueCoding.encode(value)
            case .data(let value): .blob(value)
            case .uuid(let value): try ValueCoding.encode(value)
            case .url(let value): .text(value.absoluteString)
            case .ids(let value): .text(String(decoding: try CanonicalJSON.encode(value), as: UTF8.self))
            case .reference(let id, _): try ValueCoding.encode(id)
            }
        }
    }
}

typealias SyncFields = [String: SyncValue]

extension SyncFields {
    init?(fieldValues: [String: any Sendable]) {
        var fields: SyncFields = [:]
        for (key, value) in fieldValues {
            guard let value = SyncValue(fieldValue: value) else { return nil }
            fields[key] = value
        }
        self = fields
    }

    var fieldValues: [String: any Sendable] { mapValues(\.fieldValue) }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decoded(_ value: SQLiteValue?) -> SyncFields? {
        guard case .blob(let data)? = value else { return nil }
        return try? JSONDecoder().decode(SyncFields.self, from: data)
    }
}

/// A record kept back because this version of the app can't store it, to try again after an update.
private struct ParkedRecord: Codable {
    let type: String
    let id: UUID
    let fields: SyncFields?
    let tag: Data?
    let modified: Date?
}

/// A change the server doesn't have yet.
struct PendingChange: Hashable, Sendable {
    let table: String
    let id: UUID
    let kind: RecordChange.Kind
    let version: Int
}

// MARK: - Registered types

extension RecordStore {
    /// Registers record types and every type their relationships reach, creating their tables and join
    /// tables and applying renames and indexes now rather than on first use.
    ///
    /// Every type is checked before anything is written, so a setup mistake fails when the container
    /// opens instead of mixing up data later. `syncSafe` also requires names a server such as CloudKit accepts.
    func register(_ types: [any Record.Type], syncSafe: Bool = false) throws {
        var found: [String: any Record.Type] = [:]
        var queue = types
        while let type = queue.popLast() {
            if let other = found[type.table] ?? registered[type.table] {
                guard ObjectIdentifier(other) == ObjectIdentifier(type) else {
                    throw RecordsError.invalidSchema(
                        type: type.table, reason: "\(other) and \(type) are both stored as \"\(type.table)\". Give one a different @Record(name:)."
                    )
                }
                continue
            }
            found[type.table] = type
            queue += Self.relatedTypes(type)
        }
        for type in found.values {
            try Self.validate(type, syncSafe: syncSafe)
        }
        try transaction {
            for (table, type) in found where registered[table] == nil {
                registered[table] = type
                try prepareRegistered(type)
            }
        }
    }

    /// The types a type's relationships, references and inverses name.
    private static func relatedTypes<R: Record>(_ type: R.Type) -> [any Record.Type] {
        R.schema.fields.compactMap { field in
            if let inverse = field.inverse ?? field.parent {
                return Swift.type(of: inverse).rootType as? any Record.Type
            }
            return relationTarget(field)
        }
    }

    /// Checks what the macro can't see from inside one type: relationships whose targets say how they
    /// belong, references and inverses that point back, renames that don't collide, and with sync, names a
    /// server accepts.
    private static func validate<R: Record>(_ type: R.Type, syncSafe: Bool) throws {
        func invalid(_ reason: String) -> RecordsError {
            .invalidSchema(type: R.table, reason: reason)
        }
        let names = Set(R.schema.fields.map(\.name))
        var oldNames: [String: String] = [:]
        for field in R.schema.fields {
            if let target = relationTarget(field), !declaresRelationship(target, field.keyPath) {
                throw invalid(
                    "\(field.name) links to \(target), which doesn't say how it belongs. Give \(target) "
                        + "@Reference(to: \\\(R.self).\(field.name)) if each one has one parent, or "
                        + "@Reference(from: \\\(R.self).\(field.name)) if it can have several."
                )
            }
            if let parent = field.parent {
                guard let owner = Swift.type(of: parent).rootType as? any Record.Type,
                      let target = forwardTarget(of: owner, keyPath: parent), ObjectIdentifier(target) == ObjectIdentifier(R.self) else {
                    throw invalid("\(field.name) is a reference to \(parent), which isn't a relationship to \(R.self).")
                }
                if R.schema.fields.contains(where: { $0.parent == parent && $0.name != field.name }) {
                    throw invalid("Two properties are references to \(parent). Keep one.")
                }
            }
            if let inverse = field.inverse {
                guard let owner = Swift.type(of: inverse).rootType as? any Record.Type else {
                    throw invalid("\(field.name) is an inverse of \(inverse), which isn't a property of a @Record type.")
                }
                guard let target = forwardTarget(of: owner, keyPath: inverse), ObjectIdentifier(target) == ObjectIdentifier(R.self) else {
                    throw invalid("\(field.name) is an inverse of \(inverse), which isn't a relationship to \(R.self).")
                }
            }
            for old in field.previousNames {
                if old != field.name, names.contains(old) {
                    throw invalid("\(field.name) is renamed from \"\(old)\", which is still a property's name.")
                }
                if let other = oldNames.updateValue(field.name, forKey: old), other != field.name {
                    throw invalid("\(other) and \(field.name) are both renamed from \"\(old)\".")
                }
            }
            if syncSafe, !isSyncSafe(field.name) {
                throw invalid("\"\(field.name)\" can't sync. Use letters, digits and underscores, starting with a letter.")
            }
        }
        if syncSafe, !isSyncSafe(R.table) {
            throw invalid("\"\(R.table)\" can't sync. Use @Record(name:) with letters, digits and underscores, starting with a letter.")
        }
    }

    /// True when `target` has a `@Reference(to:)` or `@Reference(from:)` property for the relationship at `keyPath`.
    private static func declaresRelationship(_ target: any Record.Type, _ keyPath: AnyKeyPath) -> Bool {
        func check<T: Record>(_ type: T.Type) -> Bool {
            T.schema.fields.contains { $0.parent == keyPath || $0.inverse == keyPath }
        }
        return check(target)
    }

    /// The related type of the forward relationship a key path names, or `nil` if it names none.
    private static func forwardTarget<O: Record>(of owner: O.Type, keyPath: AnyKeyPath) -> (any Record.Type)? {
        O.schema.field(for: keyPath).flatMap(relationTarget)
    }

    /// Letters, digits and underscores, starting with a letter and at most 255 long, which CloudKit
    /// accepts for record types and field names.
    static func isSyncSafe(_ name: String) -> Bool {
        let isLetter = { (c: Unicode.Scalar) in ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
        guard let first = name.unicodeScalars.first, isLetter(first), name.unicodeScalars.count <= 255 else { return false }
        return name.unicodeScalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Creates a registered type's table and join tables.
    private func prepareRegistered<R: Record>(_ type: R.Type) throws {
        try ensureTable(R.table)
        try prepare(R.self)
        for field in R.schema.fields {
            guard let target = Self.relationTarget(field) else { continue }
            _ = try ensureRelation(R.self, field: field, target: target)
        }
    }

    /// The related type of a forward relationship property, such as `Note` for `[Note]` or `Person?`.
    static func relationTarget<R: Record>(_ field: RecordSchema<R>.Field) -> (any Record.Type)? {
        guard field.inverse == nil, !field.isAsset else { return nil }
        let valueType = Swift.type(of: field.keyPath).valueType
        if let collection = valueType as? any RecordCollection.Type {
            return collection.recordType
        }
        return valueType as? any Record.Type
    }
}

// MARK: - Fields in and out

extension RecordStore {
    /// A stored record's values as a server sees them, including fields from newer app versions, or `nil`
    /// when the record isn't stored or its type isn't registered.
    func syncFields(table: String, id: SQLiteValue) throws -> SyncFields? {
        guard let type = registered[table] else { return nil }
        return try syncFields(type, id: id)
    }

    private func syncFields<R: Record>(_ type: R.Type, id: SQLiteValue) throws -> SyncFields? {
        guard tableExists(R.table), let row = try db.run("SELECT * FROM \(quoted(R.table)) WHERE id = ?", [id]).first else {
            return nil
        }
        var fields = SyncFields.decoded(try syncRow(R.table, id: id)?["extra"]) ?? [:]
        for field in R.schema.fields where field.name != "id" && field.inverse == nil && field.timestamp != .synced {
            fields[field.name] = nil
            if Self.relationTarget(field) != nil {
                let join = R.table + "." + field.name
                let targets = tableExists(join)
                    ? try db.run("SELECT target FROM \(quoted(join)) WHERE owner = ? ORDER BY position", [id])
                        .map { try ValueCoding.decode(UUID.self, from: $0["target"] ?? .null) }
                    : []
                fields[field.name] = .ids(targets)
            } else if field.isAsset {
                if case .text(let name)? = row[field.name] {
                    fields[field.name] = .url(assetURL(named: name))
                }
            } else if field.parent != nil {
                if let value = row[field.name], value != .null {
                    fields[field.name] = .reference(try ValueCoding.decode(UUID.self, from: value), field.action)
                }
            } else if let value = row[field.name], value != .null {
                fields[field.name] = try Self.syncValue(of: value, as: Swift.type(of: field.keyPath).valueType)
            }
        }
        return fields
    }

    /// Decodes a column as its property's type, so a `Bool` or `Date` crosses as itself rather than a number.
    private static func syncValue(of value: SQLiteValue, as valueType: Any.Type) throws -> SyncValue? {
        guard let decodable = valueType as? any Decodable.Type else { return nil }
        func decode<T: Decodable>(_ type: T.Type) throws -> Any {
            try ValueCoding.decode(T.self, from: value)
        }
        return try SyncValue(property: decode(decodable))
    }

    /// Converts a field to its property's column, checking that it decodes as the property's type.
    private static func column(_ value: SyncValue, as valueType: Any.Type) throws -> SQLiteValue {
        guard let codable = valueType as? any Codable.Type else {
            throw DecodingError.typeMismatch(valueType, .init(codingPath: [], debugDescription: "Not Codable"))
        }
        func convert<T: Codable>(_ type: T.Type) throws -> SQLiteValue {
            let typed: T
            if case .data(let json) = value, T.self != Data.self, T.self != Data?.self {
                typed = try ValueCoding.jsonDecoder.decode(T.self, from: json)
            } else {
                typed = try ValueCoding.decode(T.self, from: value.sqliteValue)
            }
            return try ValueCoding.encode(typed)
        }
        return try convert(codable)
    }

    /// Writes a record's values, logged or not depending on whether this runs inside
    /// `applyingSyncedChanges`. Fields this version doesn't know are kept beside the record, and fields
    /// under a `@Renamed` property's old name are read as the new one. Throws `incompatibleRecord`, before
    /// writing anything, when a value doesn't fit its property.
    func applySyncFields(table: String, id: UUID, fields: SyncFields) throws {
        guard let type = registered[table] else { throw RecordsError.incompatibleRecord(type: table, id: id) }
        try applySyncFields(type, id: id, fields: fields)
    }

    private func applySyncFields<R: Record>(_ type: R.Type, id: UUID, fields: SyncFields) throws {
        let sqlID = try ValueCoding.encode(id)
        var known: Set<String> = ["id"]
        var columns: [(name: String, value: SQLiteValue)] = []
        var links: [(field: RecordSchema<R>.Field, target: any Record.Type, ids: [SQLiteValue])] = []
        var assets: [String: Asset] = [:]
        do {
            for field in R.schema.fields where field.name != "id" {
                known.insert(field.name)
                known.formUnion(field.previousNames)
                guard field.inverse == nil, field.timestamp != .synced else { continue }
                let value = fields[field.name] ?? field.previousNames.lazy.compactMap { fields[$0] }.first
                if let target = Self.relationTarget(field) {
                    guard case .ids(let ids) = value ?? .ids([]) else { throw RecordsError.incompatibleRecord(type: R.table, id: id) }
                    links.append((field, target, try ids.map { try ValueCoding.encode($0) }))
                } else if field.isAsset {
                    switch value {
                    case .url(let url)?: assets[field.name] = Asset(storedName: url.lastPathComponent, url: url)
                    case nil: break
                    default: throw RecordsError.incompatibleRecord(type: R.table, id: id)
                    }
                } else if let value {
                    columns.append((field.name, try Self.column(value, as: Swift.type(of: field.keyPath).valueType)))
                }
            }
        } catch {
            throw RecordsError.incompatibleRecord(type: R.table, id: id)
        }

        try ensureTable(R.table)
        try prepare(R.self)
        columns += try storeAssets(of: R.self, id: sqlID, assets: assets)
        try ensureColumns(columns.map(\.name), in: R.table)
        let references = try referenceValues(R.self, id: sqlID)
        try upsert(columns, id: sqlID, into: R.table)
        try reconcileReferences(R.self, id: sqlID, before: references)
        for (field, target, ids) in links {
            try link(try ensureRelation(R.self, field: field, target: target), ownerID: sqlID, targets: ids)
        }
        let extra = fields.filter { !known.contains($0.key) }
        if extra.isEmpty {
            try db.run("UPDATE \"_records_sync\" SET extra = NULL WHERE record_table = ? AND record_id = ?", [.text(R.table), sqlID])
        } else {
            try updateSyncRow(R.table, id: sqlID, ["extra": .blob(try extra.encoded())])
        }
    }
}

// MARK: - What the server has

extension RecordStore {
    /// The sync bookkeeping for one record: what the server acknowledged, its last tag after a delete, the
    /// snapshot and any fields from newer app versions.
    func syncRow(_ table: String, id: SQLiteValue) throws -> [String: SQLiteValue]? {
        try db.run("SELECT * FROM \"_records_sync\" WHERE record_table = ? AND record_id = ?", [.text(table), id]).first
    }

    /// Sets columns of a record's sync row, creating it if needed.
    func updateSyncRow(_ table: String, id: SQLiteValue, _ values: [String: SQLiteValue]) throws {
        try db.run(
            "INSERT OR IGNORE INTO \"_records_sync\" (record_table, record_id) VALUES (?, ?)", [.text(table), id]
        )
        let names = values.keys.sorted()
        guard !names.isEmpty else { return }
        try db.run(
            "UPDATE \"_records_sync\" SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE record_table = ? AND record_id = ?",
            names.map { values[$0]! } + [.text(table), id]
        )
    }

    /// Before the first local change to a record the server has, keeps the synced values as the ancestor
    /// for a three-way merge. Only a container with a provider does this.
    func snapshotBeforeChange(_ table: String, id: SQLiteValue) throws {
        guard syncEnabled, applyingSynced == 0,
              let row = try syncRow(table, id: id), row["known"] == .integer(1), row["snapshot"] == .null,
              let fields = try syncFields(table: table, id: id) else { return }
        try updateSyncRow(table, id: id, ["snapshot": .blob(try fields.encoded())])
    }

    /// Keeps a deleted record's tag, which its deletion is sent with.
    func keepTagOfDeletedRow(_ table: String, id: SQLiteValue) throws {
        guard syncEnabled, columns[table, default: []].contains("_tag"), try syncRow(table, id: id) != nil else { return }
        let tag = try db.run("SELECT \"_tag\" FROM \(quoted(table)) WHERE id = ?", [id]).first?["_tag"] ?? .null
        try updateSyncRow(table, id: id, ["tag": tag])
    }

    private func logEntry(_ table: String, id: SQLiteValue) throws -> (kind: RecordChange.Kind, version: Int)? {
        guard let row = try db.run(
            "SELECT kind, version FROM \"_records_changes\" WHERE record_table = ? AND record_id = ?", [.text(table), id]
        ).first, case .text(let kind) = row["kind"], let kind = RecordChange.Kind(rawValue: kind) else { return nil }
        return (kind, Int(row["version"]?.integerValue ?? 0))
    }

    private func dropLogEntry(_ table: String, id: SQLiteValue) throws {
        try db.run("DELETE FROM \"_records_changes\" WHERE record_table = ? AND record_id = ?", [.text(table), id])
    }

    private func setTagColumn(_ tag: Data?, table: String, id: SQLiteValue) throws {
        guard tableExists(table) else { return }
        try ensureTable(table)
        try db.run("UPDATE \(quoted(table)) SET \"_tag\" = ? WHERE id = ?", [tag.map { .blob($0) } ?? .null, id])
    }

    /// Every change the server doesn't have, oldest first.
    func pendingChanges() throws -> [PendingChange] {
        try locked {
            try db.run("""
                SELECT c.record_table, c.record_id, c.kind, c.version FROM "_records_changes" c
                LEFT JOIN "_records_sync" s ON s.record_table = c.record_table AND s.record_id = c.record_id
                WHERE c.version > COALESCE(s.acked, 0) ORDER BY c.seq
                """).compactMap { row in
                guard case .text(let table) = row["record_table"], case .text(let kind) = row["kind"],
                      let kind = RecordChange.Kind(rawValue: kind) else { return nil }
                return PendingChange(
                    table: table, id: try ValueCoding.decode(UUID.self, from: row["record_id"] ?? .null), kind: kind,
                    version: Int(row["version"]?.integerValue ?? 0)
                )
            }
        }
    }

    /// The record to send for a pending change, with the fields it carries. `nil` when the record is gone
    /// or its type isn't registered.
    func syncRecord(for change: PendingChange) throws -> (record: SyncRecord, fields: SyncFields?)? {
        try locked {
            let id = try ValueCoding.encode(change.id)
            if change.kind == .delete {
                var tag: Data?
                if case .blob(let data)? = try syncRow(change.table, id: id)?["tag"] { tag = data }
                return (SyncRecord(type: change.table, id: change.id, fields: nil, tag: tag), nil)
            }
            guard let fields = try syncFields(table: change.table, id: id) else { return nil }
            let row = try db.run("SELECT \"_tag\", \"_modified\" FROM \(quoted(change.table)) WHERE id = ?", [id]).first
            var tag: Data?
            if case .blob(let data)? = row?["_tag"] { tag = data }
            var modified: Date?
            if case .real(let time)? = row?["_modified"] { modified = Date(timeIntervalSince1970: time) }
            var record = SyncRecord(type: change.table, id: change.id, fields: fields.fieldValues, tag: tag, modified: modified)
            record.parent = registered[change.table].flatMap { Self.parent(of: $0, in: fields) }
            return (record, fields)
        }
    }

    /// The parent a server should file a record under, such as a `CKRecord`'s `parent`: its first `.deleteSelf`
    /// reference that is set, or else its first reference that is set.
    private static func parent<R: Record>(of type: R.Type, in fields: SyncFields) -> UUID? {
        let references = R.schema.fields.filter { $0.parent != nil }
        let ordered = references.filter { $0.action == .deleteSelf } + references.filter { $0.action != .deleteSelf }
        for field in ordered {
            if case .reference(let id, _)? = fields[field.name] { return id }
        }
        return nil
    }

    /// A server's fields with each child reference as a `.reference`, whichever form the provider handed
    /// back, so it compares equal to the same reference sent from here.
    private static func normalizingReferences<R: Record>(of type: R.Type, in fields: SyncFields) -> SyncFields {
        var fields = fields
        for field in R.schema.fields where field.parent != nil {
            switch fields[field.name] {
            case .uuid(let id)?: fields[field.name] = .reference(id, field.action)
            case .string(let text)?: fields[field.name] = UUID(uuidString: text).map { .reference($0, field.action) }
            case .reference(let id, _)?: fields[field.name] = .reference(id, field.action)
            default: break
            }
        }
        return fields
    }

    /// Records that the server has a change. A later local edit stays pending, with what was sent as its ancestor.
    func acknowledge(_ change: PendingChange, sent fields: SyncFields?, tag: Data?) throws {
        let id = try ValueCoding.encode(change.id)
        guard let entry = try logEntry(change.table, id: id) else { return }
        if change.kind == .delete {
            if entry.kind == .delete {
                // The tombstone has done its job.
                try dropLogEntry(change.table, id: id)
                try db.run("DELETE FROM \"_records_sync\" WHERE record_table = ? AND record_id = ?", [.text(change.table), id])
            }
            return
        }
        let acked = max(change.version, Int(try syncRow(change.table, id: id)?["acked"]?.integerValue ?? 0))
        let snapshot: SQLiteValue = entry.version > change.version ? (try fields.map { .blob(try $0.encoded()) } ?? .null) : .null
        // A record deleted since this was sent keeps the new tag for its deletion.
        let deletedTag: SQLiteValue = entry.kind == .delete ? (tag.map { .blob($0) } ?? .null) : .null
        try updateSyncRow(change.table, id: id, [
            "acked": .integer(Int64(acked)), "known": .integer(1), "snapshot": snapshot, "tag": deletedTag,
            "synced_at": .real(Date().timeIntervalSince1970),
        ])
        // Views showing a synced timestamp refresh.
        changedData = true
        if entry.kind == .save {
            try setTagColumn(tag, table: change.table, id: id)
        }
    }

    /// Applies records from the server, merging any that have unsent local edits. Returns the ones this
    /// version of the app can't store, which are kept to try again after an update.
    func applyReceived(_ records: [SyncRecord], policy: MergePolicy) throws -> [SyncRecord] {
        var incompatible: [SyncRecord] = []
        for record in records {
            do {
                try transaction { try applyReceived(record, policy: policy) }
            } catch RecordsError.incompatibleRecord {
                incompatible.append(record)
                try park(record)
            }
        }
        return incompatible
    }

    private func applyReceived(_ record: SyncRecord, policy: MergePolicy) throws {
        let table = record.type
        let id = try ValueCoding.encode(record.id)
        let entry = try logEntry(table, id: id)
        let sync = try syncRow(table, id: id)
        let pending = entry.map { $0.version > Int(sync?["acked"]?.integerValue ?? 0) } ?? false

        guard let values = record.fields else {
            // A server delete beats a local edit, unless local changes always win.
            if pending, entry?.kind == .save, policy == .localWins {
                try updateSyncRow(table, id: id, ["acked": .integer(0), "known": .integer(0), "snapshot": .null, "tag": .null])
                try setTagColumn(nil, table: table, id: id)
                return
            }
            try applyingSyncedChanges { try deleteRow(table, id: id) }
            try dropLogEntry(table, id: id)
            try db.run("DELETE FROM \"_records_sync\" WHERE record_table = ? AND record_id = ?", [.text(table), id])
            return
        }
        guard let type = registered[table], let server = SyncFields(fieldValues: values).map({ Self.normalizingReferences(of: type, in: $0) }) else {
            throw RecordsError.incompatibleRecord(type: table, id: record.id)
        }

        if pending, let entry {
            if entry.kind == .delete, policy != .serverWins {
                // A local delete beats a server edit. It goes with the server's latest tag.
                try updateSyncRow(table, id: id, ["known": .integer(1), "tag": record.tag.map { .blob($0) } ?? .null])
                return
            }
            if entry.kind == .save {
                let local = try syncFields(table: table, id: id) ?? [:]
                let localModified = try db.run("SELECT \"_modified\" FROM \(quoted(table)) WHERE id = ?", [id]).first?["_modified"]
                var localIsLater = false
                if case .real(let time)? = localModified, let serverTime = record.modified {
                    localIsLater = time > serverTime.timeIntervalSince1970
                }
                let merged = SyncMerge.merge(
                    local: local, server: server, base: SyncFields.decoded(sync?["snapshot"]), policy: policy, localIsLater: localIsLater
                )
                // The server's copy is the ancestor of whatever is sent next.
                try updateSyncRow(table, id: id, ["known": .integer(1), "snapshot": .blob(try server.encoded())])
                try applySyncFields(table: table, id: record.id, fields: merged)
                try setTagColumn(record.tag, table: table, id: id)
                if merged == server {
                    let version = try logEntry(table, id: id)?.version ?? 0
                    try updateSyncRow(table, id: id, [
                        "acked": .integer(Int64(version)), "snapshot": .null, "synced_at": .real(Date().timeIntervalSince1970),
                    ])
                }
                return
            }
            // A server edit undoes the local delete.
            try dropLogEntry(table, id: id)
        }

        try applyingSyncedChanges { try applySyncFields(table: table, id: record.id, fields: server) }
        let version = try logEntry(table, id: id)?.version ?? 0
        try updateSyncRow(table, id: id, [
            "acked": .integer(Int64(version)), "known": .integer(1), "snapshot": .null, "tag": .null,
            "synced_at": .real(Date().timeIntervalSince1970),
        ])
        try setTagColumn(record.tag, table: table, id: id)
    }

    private func park(_ record: SyncRecord) throws {
        let parked = ParkedRecord(
            type: record.type, id: record.id, fields: record.fields.flatMap { SyncFields(fieldValues: $0) }, tag: record.tag,
            modified: record.modified
        )
        try db.run(
            "INSERT OR REPLACE INTO \"_records_parked\" (record_table, record_id, record) VALUES (?, ?, ?)",
            [.text(record.type), try ValueCoding.encode(record.id), .blob(try JSONEncoder().encode(parked))]
        )
    }

    /// Tries records kept back by an earlier version of the app again. Returns the ones still incompatible.
    func retryParked(policy: MergePolicy) throws -> [SyncRecord] {
        try transaction {
            let records = try db.run("SELECT record FROM \"_records_parked\"").compactMap { row -> SyncRecord? in
                guard case .blob(let data)? = row["record"], let parked = try? JSONDecoder().decode(ParkedRecord.self, from: data) else {
                    return nil
                }
                return SyncRecord(type: parked.type, id: parked.id, fields: parked.fields?.fieldValues, tag: parked.tag, modified: parked.modified)
            }
            guard !records.isEmpty else { return [] }
            try db.run("DELETE FROM \"_records_parked\"")
            return try applyReceived(records, policy: policy)
        }
    }

    /// Makes every stored record pending as if never sent, for a first sign-in, an account that keeps
    /// local data or a server reset. Tags and snapshots from the old server are dropped.
    func markAllPending() throws {
        try transaction {
            try db.run("UPDATE \"_records_sync\" SET acked = 0, known = 0, tag = NULL, snapshot = NULL")
            try db.run("DELETE FROM \"_records_sync\" WHERE extra IS NULL")
            try db.run("DELETE FROM \"_records_changes\" WHERE kind = 'delete'")
            let now = SQLiteValue.real(Date().timeIntervalSince1970)
            for table in registered.keys.sorted() where tableExists(table) {
                try ensureTable(table)
                try db.run("UPDATE \(quoted(table)) SET \"_tag\" = NULL")
                try db.run(
                    """
                    INSERT OR IGNORE INTO "_records_changes" (record_table, record_id, kind, version, time)
                    SELECT ?, id, 'save', MAX("_version", 1), COALESCE("_modified", ?) FROM \(quoted(table)) ORDER BY "_position", rowid
                    """,
                    [.text(table), now]
                )
            }
        }
    }
}
