import Foundation

// A record's fields as they cross to a server, as `RecordValue`s shaped like a `CKRecord`'s, and back. A
// record carries only its own values: a `@Reference(from:)` pointer is a reference, and the arrays pointers
// and links fill are left out, since they're other records. Empty lists are left out, as CloudKit leaves them out.

extension RecordStore {
    // MARK: Fields to values

    /// A record's fields as they cross to a server.
    static func recordValues<R: Record>(_ type: R.Type, fields: SyncFields) throws -> [String: RecordValue] {
        let schema = Dictionary(R.cachedSchema.fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var values: [String: RecordValue] = [:]
        for (key, value) in fields {
            guard let field = schema[key] else {
                values[key] = recordValue(value)
                continue
            }
            let valueType = Swift.type(of: field.keyPath).valueType
            switch value {
            case .url(let url) where field.isAsset:
                values[key] = .asset(url.lastPathComponent)
            case .data(let json) where !isData(valueType):
                values[key] = try recordList(json, as: valueType) ?? .bytes(json)
            default:
                values[key] = recordValue(value)
            }
        }
        return values
    }

    /// A field's value as it crosses, for a field no property describes.
    static func recordValue(_ value: SyncValue) -> RecordValue {
        switch value {
        case .string(let value): .string(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .bool(let value): .int(value ? 1 : 0)
        case .date(let value): .date(value)
        case .data(let value): .bytes(value)
        case .uuid(let value): .string(value.uuidString)
        case .url(let value): .string(value.absoluteString)
        case .reference(let id, let action): .reference(id, action: action)
        case .unknown(let value): value
        }
    }

    /// A list of strings, numbers or dates as CloudKit's own list, rather than JSON.
    private static func recordList(_ json: Data, as valueType: Any.Type) throws -> RecordValue? {
        let decoder = ValueCoding.jsonDecoder
        if valueType == [String].self || valueType == [String]?.self {
            return .strings(try decoder.decode([String].self, from: json))
        }
        if integerLists.contains(where: { $0 == valueType }) {
            return .ints(try decoder.decode([Int64].self, from: json))
        }
        if valueType == [Double].self || valueType == [Double]?.self || valueType == [Float].self || valueType == [Float]?.self {
            return .doubles(try decoder.decode([Double].self, from: json))
        }
        if valueType == [Date].self || valueType == [Date]?.self {
            return .dates(try decoder.decode([Date].self, from: json))
        }
        return nil
    }

    private static let integerLists: [Any.Type] = [
        [Int].self, [Int]?.self, [Int64].self, [Int64]?.self, [Int32].self, [Int32]?.self, [Int16].self, [Int16]?.self,
        [Int8].self, [Int8]?.self, [UInt32].self, [UInt32]?.self, [UInt16].self, [UInt16]?.self, [UInt8].self, [UInt8]?.self,
    ]

    private static func isData(_ valueType: Any.Type) -> Bool {
        valueType == Data.self || valueType == Data?.self
    }

    /// The values a struct crosses as, from the struct alone: no container, no stored row and no sync
    /// history. Each field maps as a stored record's does. A pointer is whatever the struct holds, since
    /// only saving it through its parent sets it, and an asset that isn't a file yet is written to a
    /// temporary one. `files` holds each asset's file by its ID.
    static func recordValues<R: Record>(of record: R) throws -> (values: [String: RecordValue], files: [String: URL]) {
        let encoded = try RecordEncoder.encode(record)
        let columns = Dictionary(encoded.columns, uniquingKeysWith: { _, last in last })
        var fields: SyncFields = [:]
        var files: [String: URL] = [:]
        for field in R.cachedSchema.fields where field.name != "id" && field.isStored && field.timestamp != .synced {
            if field.isAsset {
                if let storage = encoded.assets[field.name]?.storage {
                    let file = try file(of: storage)
                    files[file.lastPathComponent] = file
                    fields[field.name] = .url(file)
                }
            } else if field.timestamp != nil {
                // The encoder leaves timestamps to the container, so they're read from the struct.
                if let date = record[keyPath: field.keyPath] as? Date {
                    fields[field.name] = try SyncValue(property: date)
                }
            } else if let value = columns[field.name], value != .null {
                fields[field.name] = field.isPointer
                    ? .reference(try ValueCoding.decode(UUID.self, from: value), action: field.action)
                    : try syncValue(of: value, as: Swift.type(of: field.keyPath).valueType)
            }
        }
        return (try recordValues(R.self, fields: fields), files)
    }

    /// An asset's file, written to the temporary folder if it's only in memory.
    private static func file(of storage: Asset.Storage) throws -> URL {
        switch storage.source {
        case .file(let url), .stored(let url):
            return url
        case .data(let data):
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(storage.name)
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    // MARK: Values to fields

    /// The container's typed fields for values from a server, each typed as a stored value of its property is.
    /// Throws when a value doesn't fit its property.
    func syncFields<R: Record>(_ type: R.Type, values: [String: RecordValue]) throws -> SyncFields {
        var schema: [String: RecordSchema<R>.Field] = [:]
        for field in R.cachedSchema.fields where field.name != "id" {
            for name in [field.name] + field.previousNames where schema[name] == nil {
                schema[name] = field
            }
        }
        func mismatch() -> DecodingError {
            DecodingError.typeMismatch(R.self, .init(codingPath: [], debugDescription: "A value doesn't fit its property"))
        }
        var fields: SyncFields = [:]
        for (key, value) in values where key != "id" {
            guard let field = schema[key] else {
                fields[key] = .unknown(value)
                continue
            }
            if !field.isStored || field.timestamp == .synced {
                continue
            } else if field.isAsset {
                guard case .asset(let id) = value else { throw mismatch() }
                fields[key] = .url(assetURL(named: id))
            } else if field.isPointer {
                switch value {
                case .reference(let id, _): fields[key] = .reference(id, action: field.action)
                case .string(let text):
                    guard let id = UUID(uuidString: text) else { throw mismatch() }
                    fields[key] = .reference(id, action: field.action)
                default: throw mismatch()
                }
            } else {
                fields[key] = try Self.syncValue(value, as: Swift.type(of: field.keyPath).valueType)
            }
        }
        return fields
    }

    /// A value from a server typed as a stored value of a property of `valueType` is, the way
    /// `SyncValue(property:)` types it. The common primitives convert directly, and anything else decodes
    /// as the property's type first. Throws when it doesn't decode.
    static func syncValue(_ value: RecordValue, as valueType: Any.Type) throws -> SyncValue? {
        switch value {
        case .string(let text) where valueType == String.self || valueType == String?.self:
            return .string(text)
        case .int(let int) where valueType == Int.self || valueType == Int?.self || valueType == Int64.self || valueType == Int64?.self:
            return .int(int)
        case .int(let int) where valueType == Bool.self || valueType == Bool?.self:
            return .bool(int != 0)
        case .double(let double) where valueType == Double.self || valueType == Double?.self:
            return .double(double)
        case .date(let date) where valueType == Date.self || valueType == Date?.self:
            return try SyncValue(property: date)
        case .bytes(let data) where isData(valueType):
            return .data(data)
        default:
            break
        }
        guard let decodable = valueType as? any Decodable.Type else { return .unknown(value) }
        let json: Data
        let decoder: JSONDecoder
        switch value {
        case .bytes(let data):
            // Another `Codable` value's JSON, as `SyncValue(property:)` wrote it.
            json = data
            decoder = ValueCoding.jsonDecoder
        case .int(let int) where valueType == Bool.self || valueType == Bool?.self:
            json = Data((int != 0 ? "true" : "false").utf8)
            decoder = WireJSON.decoder
        default:
            json = try value.json()
            decoder = WireJSON.decoder
        }
        func decode<T: Decodable>(_ type: T.Type) throws -> Any {
            try decoder.decode(T.self, from: json)
        }
        return try SyncValue(property: decode(decodable))
    }
}

extension RecordValue {
    /// The value as plain JSON, dates in milliseconds, to decode as a property's type.
    func json() throws -> Data {
        let encoder = WireJSON.encoder
        return switch self {
        case .string(let value): try encoder.encode(value)
        case .int(let value): try encoder.encode(value)
        case .double(let value): try encoder.encode(value)
        case .date(let value): try encoder.encode(value)
        case .bytes(let value): try encoder.encode(value)
        case .strings(let value): try encoder.encode(value)
        case .ints(let value): try encoder.encode(value)
        case .doubles(let value): try encoder.encode(value)
        case .dates(let value): try encoder.encode(value)
        case .reference(let id, _): try encoder.encode(id)
        case .asset(let id): try encoder.encode(id)
        }
    }
}

extension RecordStore {
    /// The extension an asset property gives its files, or "" for none.
    func assetExtension(type: String, field: String) -> String {
        guard let type = registered[type] else { return "" }
        func find<R: Record>(_ type: R.Type) -> String {
            R.cachedSchema.fields.first { $0.name == field || $0.previousNames.contains(field) }?.fileExtension ?? ""
        }
        return find(type)
    }
}
