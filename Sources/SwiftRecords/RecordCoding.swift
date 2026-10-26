import Foundation

/// A `[Record]` or `Record?` property, recognized from its static type so empty values still count.
protocol RecordCollection {
    static var recordType: any Record.Type { get }
    static var isArray: Bool { get }
    var records: [any Record] { get }
    static func make(from records: [any Record]) -> Self
}

extension Array: RecordCollection where Element: Record {
    static var recordType: any Record.Type { Element.self }
    static var isArray: Bool { true }
    var records: [any Record] { self }
    static func make(from records: [any Record]) -> [Element] { records.compactMap { $0 as? Element } }
}

extension Optional: RecordCollection where Wrapped: Record {
    static var recordType: any Record.Type { Wrapped.self }
    static var isArray: Bool { false }
    var records: [any Record] { map { [$0] } ?? [] }
    static func make(from records: [any Record]) -> Wrapped? { records.first as? Wrapped }
}

/// One record flattened into a row and its relationships.
struct EncodedRecord {
    struct Relation {
        let name: String
        let targetType: any Record.Type
        let targets: [any Record]
    }

    var columns: [(name: String, value: SQLiteValue)] = []
    var relations: [Relation] = []
    /// Assets to store as files, keyed by field name. A nil asset is absent.
    var assets: [String: Asset] = [:]
}

// MARK: - Nested containers

/// What a record's own `encode(to:)` writes into a nested container. It is replayed into `JSONEncoder`
/// afterwards, so the whole nested value is stored as one JSON column.
final class NestedNode: Encodable {
    enum Entry {
        case value(any Encodable)
        case null
        case node(NestedNode)
    }

    let isKeyed: Bool
    var keyed: [(key: String, entry: Entry)] = []
    var unkeyed: [Entry] = []

    init(keyed: Bool) {
        isKeyed = keyed
    }

    func encode(to encoder: Encoder) throws {
        if isKeyed {
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, entry) in keyed {
                let key = AnyCodingKey(stringValue: key)
                switch entry {
                case .value(let value): try container.encode(value, forKey: key)
                case .null: try container.encodeNil(forKey: key)
                case .node(let node): try node.encode(to: container.superEncoder(forKey: key))
                }
            }
        } else {
            var container = encoder.unkeyedContainer()
            for entry in unkeyed {
                switch entry {
                case .value(let value): try container.encode(value)
                case .null: try container.encodeNil()
                case .node(let node): try node.encode(to: container.superEncoder())
                }
            }
        }
    }
}

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

private struct NestedKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: NestedNode
    let codingPath: [CodingKey]

    func encodeNil(forKey key: Key) throws { node.keyed.append((key.stringValue, .null)) }
    func encode<T: Encodable>(_ value: T, forKey key: Key) throws { node.keyed.append((key.stringValue, .value(value))) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let child = NestedNode(keyed: true)
        node.keyed.append((key.stringValue, .node(child)))
        return KeyedEncodingContainer(NestedKeyedContainer<NestedKey>(node: child, codingPath: codingPath + [key]))
    }

    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = NestedNode(keyed: false)
        node.keyed.append((key.stringValue, .node(child)))
        return NestedUnkeyedContainer(node: child, codingPath: codingPath + [key])
    }

    func superEncoder() -> Encoder { preconditionFailure("Records do not support superEncoder") }
    func superEncoder(forKey key: Key) -> Encoder { preconditionFailure("Records do not support superEncoder") }
}

private struct NestedUnkeyedContainer: UnkeyedEncodingContainer {
    let node: NestedNode
    let codingPath: [CodingKey]
    var count: Int { node.unkeyed.count }

    func encodeNil() throws { node.unkeyed.append(.null) }
    func encode<T: Encodable>(_ value: T) throws { node.unkeyed.append(.value(value)) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = NestedNode(keyed: true)
        node.unkeyed.append(.node(child))
        return KeyedEncodingContainer(NestedKeyedContainer<NestedKey>(node: child, codingPath: codingPath))
    }

    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = NestedNode(keyed: false)
        node.unkeyed.append(.node(child))
        return NestedUnkeyedContainer(node: child, codingPath: codingPath)
    }

    func superEncoder() -> Encoder { preconditionFailure("Records do not support superEncoder") }
}

// MARK: - Encoding

/// Encodes a record's properties: primitives become columns, the records a `@Reference(to:)` property
/// holds become relations, and anything else is stored as JSON.
final class RecordEncoder: Encoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var output = EncodedRecord()
    let inverseFields: Set<String>
    /// Nested containers opened by a record's own `encode(to:)`, stored as JSON once encoding finishes.
    var nested: [(name: String, node: NestedNode)] = []
    /// The property being encoded, to name in an error.
    var property = ""

    init(inverseFields: Set<String>) {
        self.inverseFields = inverseFields
    }

    static func encode<R: Record>(_ record: R) throws -> EncodedRecord {
        let encoder = RecordEncoder(inverseFields: Set(R.cachedSchema.fields.filter { $0.inverse != nil }.map { $0.name }))
        do {
            try record.encode(to: encoder)
            for (name, node) in encoder.nested {
                encoder.property = name
                encoder.output.columns.append((name, try ValueCoding.encode(node)))
            }
        } catch is EncodingError {
            throw RecordsError.invalidValue(type: R.table, property: encoder.property)
        }
        return encoder.output
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(RowContainer<Key>(encoder: self))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        preconditionFailure("A Record must encode with a keyed container")
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        preconditionFailure("A Record must encode with a keyed container")
    }

    private struct RowContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let encoder: RecordEncoder
        var codingPath: [CodingKey] { encoder.codingPath }

        func encodeNil(forKey key: Key) throws {
            encoder.output.columns.append((key.stringValue, .null))
        }

        func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            let name = key.stringValue
            encoder.property = name
            if value is TimestampStorage {
                // The container stamps timestamps itself.
            } else if encoder.inverseFields.contains(name) {
                // Inverses are read from the owners' links, so saving the target never changes them.
            } else if let asset = value as? Asset {
                if asset.storage != nil {
                    encoder.output.assets[name] = asset
                }
            } else if let record = value as? any Record {
                encoder.output.relations.append(.init(name: name, targetType: type(of: record), targets: [record]))
            } else if let collection = value as? any RecordCollection {
                encoder.output.relations.append(
                    .init(name: name, targetType: type(of: collection).recordType, targets: collection.records)
                )
            } else {
                encoder.output.columns.append((name, try ValueCoding.encode(value)))
            }
        }

        // A nested container in a record's own encode(to:) becomes one JSON column.
        func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            let node = NestedNode(keyed: true)
            encoder.nested.append((key.stringValue, node))
            return KeyedEncodingContainer(NestedKeyedContainer<NestedKey>(node: node, codingPath: codingPath + [key]))
        }

        func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            let node = NestedNode(keyed: false)
            encoder.nested.append((key.stringValue, node))
            return NestedUnkeyedContainer(node: node, codingPath: codingPath + [key])
        }

        func superEncoder() -> Encoder { preconditionFailure("Records do not support superEncoder") }
        func superEncoder(forKey key: Key) -> Encoder { preconditionFailure("Records do not support superEncoder") }
    }
}

// MARK: - Decoding

/// Supplies relationship and inverse values while a record decodes.
protocol RelationLoader {
    /// The records a `@Reference(to:)` property holds, in its order.
    func loadRelated<R: Record>(_ type: R.Type, ownerID: SQLiteValue, field: RecordSchema<R>.Field) throws -> [any Record]
    /// Whether a `@Reference(to:)` property holds any record.
    func hasRelated<R: Record>(_ type: R.Type, ownerID: SQLiteValue, field: RecordSchema<R>.Field) throws -> Bool
    /// The IDs of the records whose many-to-many array at `inverse` links here.
    func loadInverse(targetID: SQLiteValue, inverse: AnyKeyPath) throws -> [SQLiteValue]
    func assetURL(named name: String) -> URL
    func syncedDate(table: String, id: SQLiteValue) throws -> Date?
}

/// Decodes a record from its row, loading related records through a `RelationLoader`.
struct RecordDecoder<R: Record>: Decoder {
    let row: [String: SQLiteValue]
    let loader: RelationLoader
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(RowContainer<Key>(decoder: self))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(R.self, .init(codingPath: [], debugDescription: "A Record must decode with a keyed container"))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(R.self, .init(codingPath: [], debugDescription: "A Record must decode with a keyed container"))
    }

    private struct RowContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let decoder: RecordDecoder
        var codingPath: [CodingKey] { decoder.codingPath }
        var allKeys: [Key] { decoder.row.keys.compactMap(Key.init(stringValue:)) }

        private var id: SQLiteValue { decoder.row["id"] ?? .null }

        /// A column's value, read under the property's earlier names when a row predates `@Renamed`.
        private func stored(_ name: String) -> SQLiteValue? {
            if let value = decoder.row[name], value != .null { return value }
            for previous in R.cachedSchema.field(named: name)?.previousNames ?? [] {
                if let value = decoder.row[previous], value != .null { return value }
            }
            return decoder.row[name]
        }

        func contains(_ key: Key) -> Bool {
            let name = key.stringValue
            let field = R.cachedSchema.field(named: name)
            return stored(name) != nil || field?.timestamp == .synced || field?.isStored == false
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            let name = key.stringValue
            if R.cachedSchema.field(named: name)?.timestamp == .synced { return false }
            if let value = stored(name) { return value == .null }
            guard let field = R.cachedSchema.field(named: name), !field.isStored else { return true }
            if field.inverse != nil { return false }
            // An optional relationship with no record pointing here decodes as nil.
            return try !decoder.loader.hasRelated(R.self, ownerID: id, field: field)
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            let name = key.stringValue
            if T.self == TimestampStorage.self {
                if R.cachedSchema.field(named: name)?.timestamp == .synced {
                    return TimestampStorage(date: try decoder.loader.syncedDate(table: R.table, id: id)) as! T
                }
                guard let value = stored(name), value != .null else { return TimestampStorage(date: nil) as! T }
                return TimestampStorage(date: try ValueCoding.decode(Date.self, from: value)) as! T
            }
            if let inverse = R.cachedSchema.field(named: name)?.inverse {
                let ids = try decoder.loader.loadInverse(targetID: id, inverse: inverse)
                if T.self == InverseStorage.self {
                    return InverseStorage(ids: Set(try ids.map { try ValueCoding.decode(UUID.self, from: $0) })) as! T
                }
                return try ValueCoding.decode(T.self, fromArray: ids)
            }
            if let field = R.cachedSchema.field(named: name), field.relationship != nil {
                let records = try decoder.loader.loadRelated(R.self, ownerID: id, field: field)
                if let collectionType = T.self as? any RecordCollection.Type {
                    return collectionType.make(from: records) as! T
                }
                guard let record = records.first as? T else {
                    throw DecodingError.valueNotFound(T.self, .init(codingPath: codingPath + [key], debugDescription: "No related \(T.self)"))
                }
                return record
            }
            guard let value = stored(name), value != .null else {
                // A row saved before the property existed takes the property's declared default.
                if let fallback = R.cachedSchema.field(named: name)?.defaultValue?() as? T {
                    return fallback
                }
                guard let value = stored(name) else {
                    throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "No column \(name)"))
                }
                return try ValueCoding.decode(T.self, from: value)
            }
            if T.self == Asset.self, case .text(let fileName) = value {
                return Asset(storedName: fileName, url: decoder.loader.assetURL(named: fileName)) as! T
            }
            return try ValueCoding.decode(T.self, from: value)
        }

        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            try ValueCoding.jsonDecoder(for: column(key)).container(keyedBy: type)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
            try ValueCoding.jsonDecoder(for: column(key)).unkeyedContainer()
        }

        private func column(_ key: Key) throws -> SQLiteValue {
            guard let value = stored(key.stringValue) else {
                throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "No column \(key.stringValue)"))
            }
            return value
        }

        func superDecoder() throws -> Decoder { decoder }
        func superDecoder(forKey key: Key) throws -> Decoder { decoder }
    }
}
