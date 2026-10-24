import Foundation

/// Plain JSON for values that decode as a property's type, with dates in milliseconds.
enum WireJSON {
    /// The key a public record's owner is kept under in the container's own copy of its fields. It crosses
    /// as `SyncMetadata`'s `owner`, never among the fields.
    static let ownerKey = "_owner"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

// MARK: - Records to and from the wire

extension RecordStore {
    /// The change to upload for a pending record. `owner` is used when the record has none of its own yet.
    func change(for record: SyncRecord, zone: Zone, owner: String?) throws -> RecordChangeData {
        var metadata = SyncMetadata(synced: SyncedTag.date(record.tag), owner: owner, systemFields: record.systemFields)
        guard var fields = record.fields else {
            return RecordChangeData(id: record.id, zone: zone, type: record.type, fields: nil, metadata: metadata)
        }
        if case .string(let stored)? = fields.removeValue(forKey: WireJSON.ownerKey) {
            metadata.owner = stored
        }
        let values = try registered[record.type].map { try Self.recordValues($0, fields: fields) } ?? fields.mapValues(Self.recordValue)
        return RecordChangeData(id: record.id, zone: zone, type: record.type, fields: values, metadata: metadata)
    }

    /// The container's typed copy of a change from the server. Throws `incompatibleRecord` when its type
    /// isn't registered or a value doesn't fit its property.
    func syncRecord(from change: RecordChangeData) throws -> SyncRecord {
        var record = SyncRecord(type: change.type, id: change.id, fields: nil, tag: SyncedTag.data(change.synced))
        record.systemFields = change.metadata.systemFields
        guard var values = change.fields else { return record }
        guard let type = registered[change.type] else { throw RecordsError.incompatibleRecord(type: change.type, id: change.id) }
        do {
            // The copy dates from when the server accepted it.
            record.modified = change.synced
            values[WireJSON.ownerKey] = nil
            var fields = try syncFields(type, values: values)
            if let owner = change.metadata.owner {
                fields[WireJSON.ownerKey] = .string(owner)
            }
            record.fields = fields
            return record
        } catch {
            throw RecordsError.incompatibleRecord(type: change.type, id: change.id)
        }
    }
}

// MARK: - Assets

extension RecordStore {
    /// The zone's asset files that are here but not yet on the server, oldest name first.
    func unsentAssets(zone: Zone) throws -> [RecordAssetData] {
        try locked {
            let rows = try db.run("SELECT name FROM \"_records_assets\" WHERE uploaded = 0 ORDER BY name")
            return rows.compactMap { row in
                guard case .text(let name)? = row["name"] else { return nil }
                let file = assetURL(named: name)
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                return RecordAssetData(id: name, zone: zone, file: file)
            }
        }
    }

    /// Records that the server has these asset files.
    func markAssetsUploaded(_ ids: [String]) throws {
        try transaction {
            for id in ids {
                try db.run("UPDATE \"_records_assets\" SET uploaded = 1 WHERE name = ?", [.text(id)])
            }
        }
    }

    /// The asset files that records here use but that haven't arrived yet.
    func missingAssets() throws -> [String] {
        try locked {
            try db.run("SELECT name FROM \"_records_assets\" ORDER BY name").compactMap { row in
                guard case .text(let name)? = row["name"],
                      !FileManager.default.fileExists(atPath: assetURL(named: name).path) else { return nil }
                return name
            }
        }
    }

    /// Moves a downloaded asset file into the assets folder under its ID, where the record that uses it
    /// already points. The server already has it, so it isn't uploaded again. Returns false when no record
    /// uses it any more, and the file is dropped.
    @discardableResult
    func placeDownloadedAsset(at file: URL, id: String) throws -> Bool {
        try locked {
            let manager = FileManager.default
            let held = try !db.run("SELECT 1 FROM \"_records_assets\" WHERE name = ?", [.text(id)]).isEmpty
            guard held else {
                try? manager.removeItem(at: file)
                return false
            }
            try manager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            let destination = assetURL(named: id)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: file, to: destination)
            try markAssetsUploaded([id])
            return true
        }
    }
}
