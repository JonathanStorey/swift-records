#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

extension RecordContainer {
    /// The `CKRecord` a save becomes, or `nil` for a deletion, which you delete by `RecordContainer.recordID(for:in:)`.
    ///
    /// Each field is copied as it is: a `RecordValue` is already what CloudKit stores. A record holds only
    /// its own values. A `@Reference(from:)` pointer is a `CKRecord.Reference` with its action, and the
    /// first one with `.deleteSelf` is also the record's `parent`, as `CKShare` expects. The arrays pointers
    /// and links fill aren't fields, and each pair in a many-to-many is its own `RecordLink` record. An asset
    /// is a `CKAsset` of its file here.
    ///
    /// The change's `tag` is the server copy's archived system fields, as `change(from:zone:)` sets it, and
    /// the record is built on them, so it carries the change tag and saves as an update. A change with no
    /// tag is a new record. An asset whose file hasn't downloaded yet is left out.
    public func ckRecord(for change: RecordChangeData, in zoneID: CKRecordZone.ID) throws -> CKRecord? {
        guard let fields = change.fields else { return nil }
        let store = try storage(for: change.zone).store
        let record = try change.tag.map {
            try CKRecordEncoder.record(fromSystemFields: $0, type: change.type, id: change.id, zoneID: zoneID)
        } ?? CKRecord(recordType: change.type, recordID: Self.recordID(for: change.id, in: zoneID))
        record.fill(fields) { store.assetURL(named: $0) }
        return record
    }

    /// The change a `CKRecord` from the server stands for, and the asset files it brought. Hand the files
    /// back from `downloadAsset(id:zone:into:)` when the container asks for them by ID.
    ///
    /// The record's archived system fields become the change's `tag`, so the next upload builds on exactly
    /// the server's copy, and its `modificationDate` is the `synced` date.
    public func change(from record: CKRecord, zone: Zone) throws -> (change: RecordChangeData, assets: [RecordAssetData]) {
        let store = try storage(for: zone).store
        guard let id = UUID(uuidString: record.recordID.recordName) else {
            throw RecordsError.incompatibleRecord(type: record.recordType, id: UUID())
        }
        var fields: [String: RecordValue] = [:]
        var assets: [RecordAssetData] = []
        for key in record.allKeys() {
            guard let value = record[key] else { continue }
            if let reference = value as? CKRecord.Reference {
                guard let target = UUID(uuidString: reference.recordID.recordName) else { continue }
                fields[key] = .reference(target, action: reference.action == .deleteSelf ? .deleteSelf : .nullify)
            } else if let asset = value as? CKAsset {
                guard let file = asset.fileURL else { continue }
                // Named by its contents, so every device and every download agree on the name.
                let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
                var name = digest.map { String(format: "%02x", $0) }.joined()
                let fileExtension = store.assetExtension(type: record.recordType, field: key)
                if !fileExtension.isEmpty { name += "." + fileExtension }
                fields[key] = .asset(name)
                assets.append(RecordAssetData(id: name, zone: zone, file: file))
            } else if let number = value as? NSNumber {
                fields[key] = CFNumberIsFloatType(number as CFNumber) ? .double(number.doubleValue) : .int(number.int64Value)
            } else if let string = value as? String {
                fields[key] = .string(string)
            } else if let date = value as? Date {
                fields[key] = .date(date)
            } else if let data = value as? Data {
                fields[key] = .bytes(data)
            } else if let strings = value as? [String] {
                fields[key] = .strings(strings)
            } else if let dates = value as? [Date] {
                fields[key] = .dates(dates)
            } else if let numbers = value as? [NSNumber] {
                fields[key] = numbers.contains(where: { CFNumberIsFloatType($0 as CFNumber) })
                    ? .doubles(numbers.map(\.doubleValue)) : .ints(numbers.map(\.int64Value))
            }
        }
        let change = RecordChangeData(
            id: id, zone: zone, type: record.recordType, fields: fields, tag: Self.systemFields(of: record), synced: record.modificationDate
        )
        return (change, assets)
    }

    /// The deletion a record the server reports deleted stands for, such as from
    /// `recordWithIDWasDeletedBlock`. Returns `nil` for a record name that isn't a record's ID.
    public func deletion(of recordID: CKRecord.ID, type: CKRecord.RecordType, zone: Zone) -> RecordChangeData? {
        guard let id = UUID(uuidString: recordID.recordName) else { return nil }
        return RecordChangeData(id: id, zone: zone, type: type, fields: nil)
    }

    /// The record ID a record's `id` has in a CloudKit zone: its `uuidString` as the record name.
    public static func recordID(for id: UUID, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    /// A record's system fields, archived as `encodeSystemFields(with:)` writes them.
    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
}

extension CKRecord {
    /// Writes these values and clears the fields it no longer has. `file` finds an asset's file by its ID,
    /// and an asset whose file isn't there, such as one still downloading, keeps the record's value.
    func fill(_ values: [String: RecordValue], file: (String) -> URL?) {
        for key in allKeys() where values[key] == nil {
            setObject(nil, forKey: key)
        }
        // The record belongs to what its first `.deleteSelf` pointer names, which is how sharing finds it.
        parent = values.keys.sorted().lazy.compactMap { key -> CKRecord.Reference? in
            guard case .reference(let id, .deleteSelf)? = values[key] else { return nil }
            return CKRecord.Reference(recordID: RecordContainer.recordID(for: id, in: self.recordID.zoneID), action: .none)
        }.first
        for (key, value) in values {
            switch value {
            case .string(let value): self[key] = value
            case .int(let value): self[key] = value
            case .double(let value): self[key] = value
            case .date(let value): self[key] = value
            case .bytes(let value): self[key] = value
            case .strings(let value): self[key] = value
            case .ints(let value): self[key] = value
            case .doubles(let value): self[key] = value
            case .dates(let value): self[key] = value
            case .reference(let id, let action):
                self[key] = CKRecord.Reference(
                    recordID: RecordContainer.recordID(for: id, in: recordID.zoneID),
                    action: action == .deleteSelf ? .deleteSelf : CKRecord.ReferenceAction.none
                )
            case .asset(let id):
                if let url = file(id), FileManager.default.fileExists(atPath: url.path) {
                    self[key] = CKAsset(fileURL: url)
                }
            }
        }
    }
}

/// Turns a record into the `CKRecord` it is in CloudKit, from the struct alone: no container, no stored
/// row and no sync metadata, so the result is a new record with no change tag.
///
/// ```swift
/// let ckRecord = try CKRecordEncoder().encode(recipe)                   // CloudKit's default zone
/// let pantryRecord = try CKRecordEncoder().encode(item, zone: "pantry") // the CloudKit zone "pantry"
/// ```
///
/// Fields map as they do when the container syncs. Every stored property is a field of the same name, and
/// the record holds only its own values. A `@Reference(from:)` pointer is a `CKRecord.Reference` with its
/// action, and the first with `.deleteSelf` is also the record's `parent`. A `@Reference(to:)` array isn't
/// a field: each child is its own `CKRecord` holding its pointer, so encode it separately, and each pair in
/// a many-to-many is a `RecordLink` record, which `links(of:zone:)` encodes. Lists of strings, numbers and
/// dates are CloudKit lists, an asset is a `CKAsset`, and any other `Codable` value is its JSON as `Data`.
/// `@Timestamped(.synced)` isn't stored.
public struct CKRecordEncoder {
    public init() {}

    /// `zone` is the zone the record goes in. `.default` is CloudKit's default zone, and any other zone is
    /// the CloudKit zone of the same name.
    ///
    /// Pass the server's last copy as `systemFields`, archived with `encodeSystemFields(with:)`, so the record
    /// carries its change tag and saves as an update. Without them it's a new record.
    ///
    /// Throws `RecordsError.unsyncedZone` when `zone` is `.inMemory` or `.localOnly`, which never sync,
    /// `RecordsError.mismatchedSystemFields` when the system fields name another record, type or zone, and
    /// `RecordsError.invalidValue` when a property doesn't encode, such as a custom `encode(to:)` that throws.
    public func encode<R: Record>(_ record: R, zone: Zone = .default, systemFields: Data? = nil) throws -> CKRecord {
        guard zone.canSync else { throw RecordsError.unsyncedZone(zone) }
        let zoneID = zone == .default ? CKRecordZone.default().zoneID : CKRecordZone.ID(zoneName: zone.name, ownerName: CKCurrentUserDefaultName)
        let (values, files) = try RecordStore.recordValues(of: record)
        let ckRecord: CKRecord
        if let systemFields {
            ckRecord = try Self.record(fromSystemFields: systemFields, type: R.table, id: record.id, zoneID: zoneID)
        } else {
            ckRecord = CKRecord(recordType: R.table, recordID: RecordContainer.recordID(for: record.id, in: zoneID))
        }
        ckRecord.fill(values) { files[$0] }
        return ckRecord
    }

    /// The `RecordLink` records for each pair a record's many-to-many arrays hold, as new records. A link's
    /// name is hashed from the relationship and both ends, so it matches the one the container syncs.
    public func links<R: Record>(of record: R, zone: Zone = .default) throws -> [CKRecord] {
        let encoded = try RecordEncoder.encode(record)
        let now = Date()
        var links: [CKRecord] = []
        for relation in encoded.relations {
            guard let field = R.cachedSchema.field(named: relation.name), case .links? = field.relationship else { continue }
            let name = RecordStore.relationNames(R.self, field: field)[0]
            for (index, target) in relation.targets.enumerated() {
                let link = _RecordLink(relation: name, from: record.id, to: target.id, created: now.addingTimeInterval(Double(index) / 1000))
                links.append(try encode(link, zone: zone))
            }
        }
        return links
    }

    /// The server's last copy, rebuilt from its archived system fields, if they belong to this record. The
    /// zone's owner isn't compared, since a shared zone's records name their real owner.
    static func record(fromSystemFields data: Data, type: String, id: UUID, zoneID: CKRecordZone.ID) throws -> CKRecord {
        let mismatch = RecordsError.mismatchedSystemFields(type: type, id: id)
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { throw mismatch }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordType == type, record.recordID.recordName == id.uuidString,
              record.recordID.zoneID.zoneName == zoneID.zoneName else { throw mismatch }
        return record
    }
}
#endif
