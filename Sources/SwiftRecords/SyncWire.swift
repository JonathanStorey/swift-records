import Foundation

/// Plain JSON with dates in milliseconds, as CloudKit keeps them.
enum WireJSON {
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
    /// The change to upload for a pending record. With the server copy's fields it builds on, it names the
    /// fields that differ from that copy, and still carries every field.
    func change(for record: SyncRecord, zone: Zone, base: SyncFields? = nil) throws -> RecordChangeData {
        let values = try record.fields.map(wireValues(of: record.type))
        var change = RecordChangeData(id: record.id, zone: zone, type: record.type, fields: values, tag: record.tag)
        if values != nil {
            change.encryptedKeys = encryptedKeys(of: record.type)
        }
        // The files behind its assets, for a server that keeps them inside records.
        for case .asset(let id) in values?.values.map({ $0 }) ?? [] {
            let file = assetURL(named: id)
            if FileManager.default.fileExists(atPath: file.path) {
                change.assetFiles[id] = file
            }
        }
        if let values, let base, record.tag != nil {
            let old = try wireValues(of: record.type)(base)
            change.changedKeys = Set(values.compactMap { old[$0.key] == $0.value ? nil : $0.key })
            change.clearedKeys = Set(old.keys.filter { values[$0] == nil })
        }
        return change
    }

    /// The fields a type's `@Encrypted` properties are stored under.
    private func encryptedKeys(of type: String) -> Set<String> {
        guard let type = registered[type] else { return [] }
        func keys<R: Record>(_ type: R.Type) -> Set<String> {
            Set(R.cachedSchema.fields.filter(\.isEncrypted).map(\.name))
        }
        return keys(type)
    }

    private func wireValues(of type: String) -> (SyncFields) throws -> [String: RecordValue] {
        { fields in
            try self.registered[type].map { try Self.recordValues($0, fields: fields) } ?? fields.mapValues(Self.recordValue)
        }
    }

    /// The container's typed copy of a change from the server. Throws `incompatibleRecord` when its type
    /// isn't registered or a value doesn't fit its property.
    func syncRecord(from change: RecordChangeData) throws -> SyncRecord {
        var record = SyncRecord(type: change.type, id: change.id, fields: nil, tag: change.tag, synced: change.synced)
        guard let values = change.fields else { return record }
        guard let type = registered[change.type] else { throw RecordsError.incompatibleRecord(type: change.type, id: change.id) }
        do {
            record.fields = try syncFields(type, values: values)
            return record
        } catch {
            throw RecordsError.incompatibleRecord(type: change.type, id: change.id)
        }
    }
}

// MARK: - Assets

extension RecordStore {
    /// Moves a downloaded asset file into the assets folder under its ID, where the record that uses it
    /// already points. Returns false when no record uses it any more, and the file is dropped.
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
            return true
        }
    }
}
