import Foundation

/// How a record's fields are written as the `json` of a `RecordChangeData`: one key per stored property,
/// each value as its property's type encodes, so the JSON reads like the record itself.
enum WireJSON {
    /// The key a record's place in its type's stored order goes under.
    static let positionKey = positionField
    /// The key a record's last edit time goes under, in milliseconds since 1970.
    static let modifiedKey = "_modified"
    /// The key a public record's owner is kept under in the container's own copy of its fields. It crosses
    /// as `RecordChangeData`'s `owner`, never inside the JSON.
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

    /// Writes an object from already encoded values, its keys sorted.
    static func object(_ values: [String: Data]) throws -> Data {
        var data = Data("{".utf8)
        for (index, key) in values.keys.sorted().enumerated() {
            if index > 0 { data.append(contentsOf: Array(",".utf8)) }
            data.append(try encoder.encode(key))
            data.append(contentsOf: Array(":".utf8))
            data.append(values[key]!)
        }
        data.append(contentsOf: Array("}".utf8))
        return data
    }

    /// Splits an object into its keys and each value's own JSON.
    static func members(of json: Data) throws -> [String: Data] {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a JSON object"))
        }
        var members: [String: Data] = [:]
        for (key, value) in object where !(value is NSNull) {
            members[key] = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
        return members
    }

    /// A field this version doesn't know, written as plain JSON.
    static func untyped(_ value: SyncValue) throws -> Data {
        switch value {
        case .string(let value): try encoder.encode(value)
        case .int(let value): try encoder.encode(value)
        case .double(let value): try encoder.encode(value)
        case .bool(let value): try encoder.encode(value)
        case .date(let value): try encoder.encode(value)
        case .data(let value): try encoder.encode(value)
        case .uuid(let value): try encoder.encode(value)
        case .url(let value): try encoder.encode(value)
        case .ids(let value): try encoder.encode(value)
        case .reference(let id, _): try encoder.encode(id)
        case .json(let value): value
        }
    }
}

// MARK: - Records to and from the wire

extension RecordStore {
    /// The change to upload for a pending record. `owner` is used when the record has none of its own yet.
    func change(for record: SyncRecord, zone: Zone, owner: String?) throws -> RecordChangeData {
        let synced = SyncedTag.date(record.tag)
        guard var fields = record.fields else {
            return .delete(id: record.id, zone: zone, type: record.type, owner: owner, synced: synced)
        }
        var recordOwner = owner
        if case .string(let stored)? = fields.removeValue(forKey: WireJSON.ownerKey) {
            recordOwner = stored
        }
        var members: [String: Data] = [:]
        if let type = registered[record.type] {
            members = try wireMembers(type, fields: fields)
        } else {
            for (key, value) in fields {
                members[key] = try WireJSON.untyped(value)
            }
        }
        if let position = record.position {
            members[WireJSON.positionKey] = try WireJSON.encoder.encode(position)
        }
        if let modified = record.modified {
            members[WireJSON.modifiedKey] = try WireJSON.encoder.encode((modified.timeIntervalSince1970 * 1000).rounded())
        }
        return .save(id: record.id, zone: zone, type: record.type, json: try WireJSON.object(members), owner: recordOwner, synced: synced)
    }

    private func wireMembers<R: Record>(_ type: R.Type, fields: SyncFields) throws -> [String: Data] {
        let schema = Dictionary(R.schema.fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var members: [String: Data] = [:]
        for (key, value) in fields {
            guard let field = schema[key] else {
                members[key] = try WireJSON.untyped(value)
                continue
            }
            if field.isAsset, case .url(let url) = value {
                members[key] = try WireJSON.encoder.encode(url.lastPathComponent)
            } else if field.isAsset || Self.relationTarget(field) != nil || field.parent != nil {
                members[key] = try WireJSON.untyped(value)
            } else if case .json(let json) = value {
                members[key] = json
            } else {
                members[key] = try Self.wireValue(value, as: Swift.type(of: field.keyPath).valueType)
            }
        }
        return members
    }

    /// Encodes a value as its property's type, so a `Date` is a number of milliseconds and a struct is an object.
    private static func wireValue(_ value: SyncValue, as valueType: Any.Type) throws -> Data {
        guard let codable = valueType as? any Codable.Type else { return try WireJSON.untyped(value) }
        func encode<T: Codable>(_ type: T.Type) throws -> Data {
            let typed: T
            if case .data(let json) = value, T.self != Data.self, T.self != Data?.self {
                typed = try ValueCoding.jsonDecoder.decode(T.self, from: json)
            } else {
                typed = try ValueCoding.decode(T.self, from: value.sqliteValue)
            }
            return try WireJSON.encoder.encode(typed)
        }
        return try encode(codable)
    }

    /// The container's typed copy of a change from the server. Throws `incompatibleRecord` when its type
    /// isn't registered or a value doesn't decode as its property's type.
    func syncRecord(from change: RecordChangeData) throws -> SyncRecord {
        switch change {
        case .delete(let id, _, let type, _, let synced):
            return SyncRecord(type: type, id: id, fields: nil, tag: SyncedTag.data(synced))
        case .save(let id, _, let typeName, let json, let owner, let synced):
            guard let type = registered[typeName] else { throw RecordsError.incompatibleRecord(type: typeName, id: id) }
            do {
                var members = try WireJSON.members(of: json)
                var record = SyncRecord(type: typeName, id: id, fields: nil, tag: SyncedTag.data(synced))
                if let position = members.removeValue(forKey: WireJSON.positionKey) {
                    record.position = try WireJSON.decoder.decode(Int64.self, from: position)
                }
                if let modified = members.removeValue(forKey: WireJSON.modifiedKey) {
                    record.modified = Date(timeIntervalSince1970: try WireJSON.decoder.decode(Double.self, from: modified) / 1000)
                }
                members[WireJSON.ownerKey] = nil
                var fields = try syncFields(type, members: members)
                if let owner {
                    fields[WireJSON.ownerKey] = .string(owner)
                }
                record.fields = fields
                return record
            } catch {
                throw RecordsError.incompatibleRecord(type: typeName, id: id)
            }
        }
    }

    private func syncFields<R: Record>(_ type: R.Type, members: [String: Data]) throws -> SyncFields {
        var schema: [String: RecordSchema<R>.Field] = [:]
        for field in R.schema.fields where field.name != "id" {
            for name in [field.name] + field.previousNames where schema[name] == nil {
                schema[name] = field
            }
        }
        var fields: SyncFields = [:]
        for (key, json) in members where key != "id" {
            guard let field = schema[key] else {
                fields[key] = .json(json)
                continue
            }
            if field.inverse != nil || field.timestamp == .synced {
                continue
            } else if Self.relationTarget(field) != nil {
                fields[key] = .ids(try WireJSON.decoder.decode([UUID].self, from: json))
            } else if field.isAsset {
                fields[key] = .url(assetURL(named: try WireJSON.decoder.decode(String.self, from: json)))
            } else if field.parent != nil {
                fields[key] = .reference(try WireJSON.decoder.decode(UUID.self, from: json), action: field.action)
            } else {
                fields[key] = try Self.syncValue(wire: json, as: Swift.type(of: field.keyPath).valueType)
            }
        }
        return fields
    }

    /// Decodes a value as its property's type, then types it exactly as a stored value of that property is.
    private static func syncValue(wire json: Data, as valueType: Any.Type) throws -> SyncValue? {
        guard let decodable = valueType as? any Decodable.Type else { return .json(json) }
        func decode<T: Decodable>(_ type: T.Type) throws -> Any {
            try WireJSON.decoder.decode(T.self, from: json)
        }
        return try SyncValue(property: decode(decodable))
    }
}

// MARK: - Assets

extension RecordStore {
    /// The zone's asset files that are here but not yet on the server, oldest name first.
    func unsentAssets(zone: Zone) throws -> [RecordAssetData] {
        try locked {
            let rows = try db.run("""
                SELECT name FROM "_records_assets"
                WHERE name NOT IN (SELECT name FROM "_records_uploaded_assets") ORDER BY name
                """)
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
                try db.run("INSERT OR IGNORE INTO \"_records_uploaded_assets\" (name) VALUES (?)", [.text(id)])
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
