import Versioning
#if canImport(CloudKit)
import CloudKit

extension RecordContainer {
    /// Saves the server's version of `record`, decoded as its registered type, with its
    /// system fields as `metadata`.
    ///
    /// The record's name, from ``recordName(for:type:)``, is the row's id, and its zone and
    /// owner come from the record's zone. The decoded value merges into the row as ``save(their:id:zone:type:metadata:)``
    /// describes. A record whose type is not registered, or that the type cannot decode, was
    /// written by a version of the app this device does not know, and its values are dropped:
    /// an existing row keeps its content and takes only the record's system fields, so its next
    /// upload is sent against the server's newest version, and a new record is skipped. A `CKShare`
    /// is skipped.
    /// Each asset's file is copied into the container, since the sync engine removes it.
    /// Throws only when the database fails.
    func save(their record: CKRecord) throws(DatabaseError) {
        guard !(record is CKShare) else { return }
        let id = record.recordID.rowID
        let json: JSONRepresentation
        do {
            json = try self.json(of: record)
        } catch {
            return try update(id: id) { $0.metadata = record.systemFields }
        }
        // The sync engine removes an asset's file after the event, so the row keeps a copy.
        let stored = storingAssets(record.assetFiles, in: json, id: id)
        try save(their: stored, id: id.name, zone: id.zone, type: record.recordType, metadata: record.systemFields)
    }

    /// Saves the server's version of each of `records`, as `save(their:)` does for one record,
    /// in one transaction.
    ///
    /// ```swift
    /// try container.save(their: changes.modifications.map(\.record))
    /// ```
    func save(their records: some Sequence<CKRecord>) throws(DatabaseError) {
        try transaction(author: Self.syncAuthor) { () throws(DatabaseError) in
            for record in records { try save(their: record) }
        }
    }

    /// Saves each of `records`, which this device sent and the server saved, as
    /// `save(sent:)` does for one record, in one transaction.
    func save(sent records: some Sequence<CKRecord>) throws(DatabaseError) {
        try transaction(author: Self.syncAuthor) { () throws(DatabaseError) in
            for record in records { try save(sent: record) }
        }
    }

    /// Saves that the server no longer has each record in `ids`, as
    /// `save(deleted:)` does for one id, in one transaction.
    func save(deleted ids: some Sequence<CKRecord.ID>) throws(DatabaseError) {
        try transaction(author: Self.syncAuthor) { () throws(DatabaseError) in
            for id in ids { try save(deleted: id) }
        }
    }

    /// The records waiting to upload, as saves and deletes, for telling a sync engine what
    /// to send, as on launch after a change was saved but never handed to it.
    ///
    /// ```swift
    /// let pending = try container.pendingChanges()
    /// syncEngine.state.add(pendingRecordZoneChanges: pending.saves.map { .saveRecord($0) } + pending.deletes.map { .deleteRecord($0) })
    /// ```
    func pendingChanges() throws(DatabaseError) -> (saves: [CKRecord.ID], deletes: [CKRecord.ID]) {
        var pending: (saves: [CKRecord.ID], deletes: [CKRecord.ID]) = ([], [])
        for row in try pendingRows() {
            let recordID = CKRecord.ID(recordName: row.id, zoneID: row.zone.zoneID)
            if row.isDeleted { pending.deletes.append(recordID) } else { pending.saves.append(recordID) }
        }
        return pending
    }

    /// The record to upload for the row `id`, or `nil` when it has nothing to upload.
    ///
    /// The record starts from the row's system fields, so the server can tell which version
    /// it replaces, or, before the server first confirms it or when they cannot be read,
    /// from a new record in the row's zone. `ours` is encoded into it as the registered type,
    /// only the fields that differ from `base`, so CloudKit uploads just those, and an
    /// unchanged asset is never sent again. A field `ours` no longer has is set to `nil`, so
    /// the server clears it. A record with no `base` sends every field.
    /// A row that is synced, deleted, waiting to merge, or rejected sends nothing. A row that
    /// cannot be encoded sends nothing, with the reason in `error`. What it sends is kept as
    /// the row's `sent` until the server confirms it. Throws only when the
    /// database fails.
    ///
    /// ```swift
    /// let record = try container.send(id: RecordID(note, zone: "Notes"))
    /// ```
    func send(id: RowID) throws(DatabaseError) -> CKRecord? {
        guard let row = try row(id: id), let ours = row.ours, row.status == .waitingToUpload, !row.isDeleted else { return nil }
        let record = row.metadata.flatMap(CKRecord.init(systemFields:)) ?? CKRecord(
            recordType: row.type,
            recordID: CKRecord.ID(recordName: id.name, zoneID: id.zone.zoneID)
        )
        do {
            try CKRecordEncoder().encode(ours, as: registeredType(named: row.type), to: record, changedFrom: row.base)
        } catch {
            try update(id: id) { $0.error = "This device could not send its \(row.type): \(error)" }
            return nil
        }
        try update(id: id) { $0.sent = ours }
        return record
    }

    /// Saves that the server saved `record`, which this device sent: the row's `sent` version
    /// becomes its `base`, with the record's system fields as `metadata`.
    ///
    /// The record holds only the fields that were sent, so the row's `sent`, kept by
    /// ``send(id:)``, says what the server now has. Nothing merges, as ``Row/confirm(_:)``
    /// describes, so changes saved while the record was on its way stay waiting to upload.
    /// A row with no `sent` cannot tell, so it forgets its `base` and its next send uploads
    /// every field. Throws only when the database fails.
    func save(sent record: CKRecord) throws(DatabaseError) {
        let id = record.recordID.rowID
        try update(id: id) { row in
            row.metadata = record.systemFields
            if let sent = row.sent {
                row.confirm(sent)
            } else {
                row.ours = row.ours ?? row.base
                row.base = nil
                row.error = nil
            }
        }
    }

    /// Saves why the server did not save `record`, which this device sent.
    ///
    /// - A newer server version merges in, as `save(their:)` describes, and the next
    ///   send replaces that version.
    /// - A record the server no longer has loses its `metadata` and `base`, so the next send
    ///   creates it again with every field.
    /// - A missing zone, or a failure worth retrying, changes nothing, so the record is sent again.
    /// - Any other error is saved in `error`, and nothing more uploads until the record is saved again.
    ///
    /// Throws only when the database fails.
    func save(failed record: CKRecord, error: CKError) throws(DatabaseError) {
        if error.code == .serverRecordChanged, let server = error.serverRecord {
            return try save(their: server)
        }
        let id = record.recordID.rowID
        switch error.code {
        case .unknownItem:
            try update(id: id) { row in
                row.ours = row.ours ?? row.base
                row.metadata = nil
                row.base = nil
            }
        case let code where code.isWorthRetrying:
            return
        default:
            try update(id: id) { $0.error = error.localizedDescription }
        }
    }

    /// The id of the record to delete for the row `id`, or `nil` when it has no delete
    /// waiting to upload.
    ///
    /// ```swift
    /// let recordID = try container.send(deleted: RecordID(note, zone: "Notes"))
    /// ```
    func send(deleted id: RowID) throws(DatabaseError) -> CKRecord.ID? {
        guard let row = try row(id: id), row.isDeleted, row.status == .waitingToUpload else { return nil }
        return CKRecord.ID(recordName: id.name, zoneID: id.zone.zoneID)
    }

    /// Saves that the server no longer has the record `id`, because it confirmed this
    /// device's delete or another device deleted it, as `save(deleted:)` for a row id describes.
    func save(deleted id: CKRecord.ID) throws(DatabaseError) {
        let rowID = id.rowID
        try save(deleted: rowID)
    }

    /// Saves that the server deleted the zone `zoneID` for `reason`, as `clear(in:resending:)`
    /// describes: the zone's rows are removed, or, when the user reset their encrypted data,
    /// kept and sent again as new records once the zone is created again.
    ///
    /// ```swift
    /// for deletion in changes.deletions {
    ///     try container.save(deleted: deletion.zoneID, reason: deletion.reason)
    /// }
    /// ```
    func save(deleted zoneID: CKRecordZone.ID, reason: CKDatabase.DatabaseChange.Deletion.Reason) throws(DatabaseError) {
        try clear(in: zoneID.zone, resending: reason == .encryptedDataReset)
    }

    /// Saves why the server did not delete the record `id`, which this device sent.
    ///
    /// - A record the server no longer has is already deleted, so the row is removed.
    /// - A missing zone, or a failure worth retrying, changes nothing, so the delete is sent again.
    /// - Any other error is saved in `error`, and the delete waits until the record is deleted
    ///   or saved again.
    func save(failed id: CKRecord.ID, error: CKError) throws(DatabaseError) {
        let rowID = id.rowID
        switch error.code {
        case .unknownItem:
            try save(deleted: rowID)
        case let code where code.isWorthRetrying:
            return
        default:
            try update(id: rowID) { $0.error = error.localizedDescription }
        }
    }
}

extension RecordContainer {
    /// The sync engine's state, saved on every `stateUpdate` and read when the engine starts,
    /// or `nil` when none is saved, so the engine fetches everything.
    ///
    /// ```swift
    /// case .stateUpdate(let event):
    ///     container.engineState = event.stateSerialization
    ///
    /// CKSyncEngine.Configuration(database: database, stateSerialization: container.engineState, delegate: self)
    /// ```
    ///
    /// `clear()` removes it, since a new account starts from nothing.
    var engineState: CKSyncEngine.State.Serialization? {
        get { engineStateData.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) } }
        set { engineStateData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

private extension RecordContainer {
    /// The JSON of `record` decoded as its registered type.
    func json(of record: CKRecord) throws -> JSONRepresentation {
        try CKRecordDecoder().json(registeredType(named: record.recordType), from: record)
    }
}

private extension CKRecordDecoder {
    /// The JSON of `record` decoded as `type`, generic so a registered metatype opens here.
    func json<T: Codable>(_ type: T.Type, from record: CKRecord) throws -> JSONRepresentation {
        try JSONRepresentation(decode(type, from: record))
    }
}

private extension CKRecordEncoder {
    /// Encodes `json`, decoded as `type`, into `record`, generic so a registered metatype opens here.
    ///
    /// With a `base`, only the top-level fields whose JSON differs from it are set, since a
    /// record uploads exactly the keys set on it. A field set to `nil` is cleared on the
    /// server, on the encrypted side when the base encoded it there.
    func encode<T: Codable>(_ json: JSONRepresentation, as type: T.Type, to record: CKRecord, changedFrom base: JSONRepresentation?) throws {
        let value = try json.decode(type)
        guard let base else { return try encode(value, to: record) }
        let scratch = CKRecord(recordType: record.recordType, recordID: record.recordID)
        try encode(value, to: scratch)
        // A cleared field is in neither side of `scratch`, so the base's encoding says which
        // side it was on, by the key the type encodes it under.
        let before = CKRecord(recordType: record.recordType, recordID: record.recordID)
        if let original = try? base.decode(type) { try? encode(original, to: before) }
        let encrypted = Set(scratch.encryptedValues.allKeys() + before.encryptedValues.allKeys())
        for key in json.changedKeys(from: base) {
            if encrypted.contains(key) {
                record.encryptedValues[key] = scratch.encryptedValues[key]
            } else {
                record[key] = scratch[key]
            }
        }
        if record.parent?.recordID != scratch.parent?.recordID { record.parent = scratch.parent }
    }
}

private extension JSONRepresentation {
    /// The top-level keys whose values differ from `base`'s, including a key only one has.
    func changedKeys(from base: JSONRepresentation) -> Set<String> {
        guard case .object(let pairs) = self, case .object(let basePairs) = base else { return [] }
        return Set(pairs.map { $0.key } + basePairs.map { $0.key }).filter { self[$0] != base[$0] }
    }
}

private extension CKError.Code {
    /// A missing zone, or a failure that may pass, after which a record is sent again unchanged.
    var isWorthRetrying: Bool {
        switch self {
        case .zoneNotFound, .batchRequestFailed, .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy: true
        default: false
        }
    }
}

extension Zone {
    /// The zone's CloudKit id, with its owner.
    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: owner)
    }
}

private extension CKRecordZone.ID {
    /// The zone, with its owner.
    var zone: Zone {
        Zone(zoneName, owner: ownerName)
    }
}

private extension CKRecord.ID {
    /// The row's key: the record's name, in its zone.
    var rowID: RecordContainer.RowID {
        RecordContainer.RowID(name: recordName, zone: zone)
    }

    /// The record's zone, with its owner.
    var zone: Zone {
        zoneID.zone
    }
}

private extension CKRecord {
    /// A record with the system fields archived in `systemFields`, and no values, or `nil`
    /// when they cannot be read.
    convenience init?(systemFields: Data) {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        self.init(coder: unarchiver)
    }

    /// The file of each asset field, by field.
    var assetFiles: [String: URL] {
        var files: [String: URL] = [:]
        for key in allKeys() {
            if let file = (object(forKey: key) as? CKAsset)?.fileURL { files[key] = file }
        }
        return files
    }

    /// The record's system fields, archived, without its values.
    var systemFields: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
#endif
