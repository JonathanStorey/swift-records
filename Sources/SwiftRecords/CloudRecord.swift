import Foundation

/// A field as a `CKRecord` holds it. A relationship is a list of its records' names in order, never forward
/// references, and a child's `@Reference(to:)` is the only reference a record holds.
enum CloudValue: Hashable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case date(Date)
    case bytes(Data)
    case strings([String])
    case ints([Int64])
    case doubles([Double])
    case dates([Date])
    case reference(UUID, action: ReferenceAction)
    /// An asset's file, named by its asset ID.
    case asset(URL)
}

/// A record as CloudKit stores it: its type, its record name and its fields.
struct CloudRecord: Hashable, Sendable {
    var type: String
    var id: UUID
    var fields: [String: CloudValue]
}

extension RecordStore {
    /// The record a save becomes in CloudKit, or `nil` for a deletion. Throws `incompatibleRecord` when the
    /// type isn't registered or a value doesn't decode as its property's type.
    func cloudRecord(for change: RecordChangeData) throws -> CloudRecord? {
        guard !change.isDeletion else { return nil }
        guard let type = registered[change.type], var fields = try syncRecord(from: change).fields else { return nil }
        fields[WireJSON.ownerKey] = nil
        return CloudRecord(type: change.type, id: change.id, fields: try cloudFields(type, fields: fields))
    }

    private func cloudFields<R: Record>(_ type: R.Type, fields: SyncFields) throws -> [String: CloudValue] {
        let schema = Dictionary(R.cachedSchema.fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var cloud: [String: CloudValue] = [:]
        for (key, value) in fields {
            guard let field = schema[key] else {
                cloud[key] = Self.cloudValue(value)
                continue
            }
            let valueType = Swift.type(of: field.keyPath).valueType
            switch value {
            case .ids(let ids):
                // CloudKit keeps no empty lists, and a missing list reads back as empty.
                if !ids.isEmpty { cloud[key] = .strings(ids.map(\.uuidString)) }
            case .url(let url) where field.isAsset:
                cloud[key] = .asset(url)
            case .data(let json) where !Self.isData(valueType):
                cloud[key] = try Self.cloudList(json, as: valueType) ?? .bytes(json)
            default:
                cloud[key] = Self.cloudValue(value)
            }
        }
        return cloud
    }

    private static func cloudValue(_ value: SyncValue) -> CloudValue {
        switch value {
        case .string(let value): .string(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .bool(let value): .int(value ? 1 : 0)
        case .date(let value): .date(value)
        case .data(let value): .bytes(value)
        case .uuid(let value): .string(value.uuidString)
        case .url(let value): .string(value.absoluteString)
        case .ids(let ids): .strings(ids.map(\.uuidString))
        case .reference(let id, let action): .reference(id, action: action)
        case .json(let json): cloudValue(json: json)
        }
    }

    /// A field this version doesn't know, typed by the shape of its JSON.
    private static func cloudValue(json: Data) -> CloudValue {
        let decoder = WireJSON.decoder
        if let value = try? decoder.decode(String.self, from: json) { return .string(value) }
        if let value = try? decoder.decode(Int64.self, from: json) { return .int(value) }
        if let value = try? decoder.decode(Double.self, from: json) { return .double(value) }
        if let value = try? decoder.decode([String].self, from: json) { return .strings(value) }
        if let value = try? decoder.decode([Int64].self, from: json) { return .ints(value) }
        if let value = try? decoder.decode([Double].self, from: json) { return .doubles(value) }
        return .bytes(json)
    }

    /// A list of strings, numbers or dates as CloudKit's own list, rather than JSON.
    private static func cloudList(_ json: Data, as valueType: Any.Type) throws -> CloudValue? {
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

    private static func isBool(_ valueType: Any.Type) -> Bool {
        valueType == Bool.self || valueType == Bool?.self
    }

    /// The change a record from CloudKit stands for, as if a server had sent it.
    func change(from cloud: CloudRecord, zone: Zone, owner: String?, synced: Date?) throws -> RecordChangeData {
        guard let type = registered[cloud.type] else { throw RecordsError.incompatibleRecord(type: cloud.type, id: cloud.id) }
        let members = try wireMembers(type, cloud: cloud.fields)
        return .save(id: cloud.id, zone: zone, type: cloud.type, json: try WireJSON.object(members), owner: owner, synced: synced)
    }

    private func wireMembers<R: Record>(_ type: R.Type, cloud: [String: CloudValue]) throws -> [String: Data] {
        var schema: [String: RecordSchema<R>.Field] = [:]
        for field in R.cachedSchema.fields where field.name != "id" {
            for name in [field.name] + field.previousNames where schema[name] == nil {
                schema[name] = field
            }
        }
        let encoder = WireJSON.encoder
        var members: [String: Data] = [:]
        for (key, value) in cloud {
            let valueType = schema[key].map { Swift.type(of: $0.keyPath).valueType }
            switch value {
            case .string(let value): members[key] = try encoder.encode(value)
            case .int(let value) where valueType.map(Self.isBool) ?? false: members[key] = try encoder.encode(value != 0)
            case .int(let value): members[key] = try encoder.encode(value)
            case .double(let value): members[key] = try encoder.encode(value)
            case .date(let value): members[key] = try encoder.encode(value)
            case .bytes(let value) where valueType.map(Self.isData) ?? false: members[key] = try encoder.encode(value)
            case .bytes(let value):
                // Any other value is its JSON, which a field this version doesn't know may not be.
                let isJSON = (try? JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])) != nil
                members[key] = isJSON ? value : try encoder.encode(value)
            case .strings(let value): members[key] = try encoder.encode(value)
            case .ints(let value): members[key] = try encoder.encode(value)
            case .doubles(let value): members[key] = try encoder.encode(value)
            case .dates(let value): members[key] = try encoder.encode(value)
            case .reference(let id, _): members[key] = try encoder.encode(id)
            case .asset(let url): members[key] = try encoder.encode(url.lastPathComponent)
            }
        }
        // CloudKit drops empty lists, so a relationship it lacks is empty.
        for field in R.cachedSchema.fields where Self.relationTarget(field) != nil && members[field.name] == nil {
            members[field.name] = try encoder.encode([UUID]())
        }
        return members
    }

    /// The extension an asset property gives its files, or "" for none.
    func assetExtension(type: String, field: String) -> String {
        guard let type = registered[type] else { return "" }
        func find<R: Record>(_ type: R.Type) -> String {
            R.cachedSchema.fields.first { $0.name == field || $0.previousNames.contains(field) }?.fileExtension ?? ""
        }
        return find(type)
    }
}

extension RecordContainer {
    func cloudRecord(for change: RecordChangeData) throws -> CloudRecord? {
        try storage(for: change.zone).store.cloudRecord(for: change)
    }

    func change(from cloud: CloudRecord, zone: Zone, owner: String?, synced: Date?) throws -> RecordChangeData {
        try storage(for: zone).store.change(from: cloud, zone: zone, owner: owner, synced: synced)
    }
}
