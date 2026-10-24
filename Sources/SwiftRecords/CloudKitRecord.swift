#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

extension RecordContainer {
    /// The `CKRecord` a save becomes, or `nil` for a deletion, which you delete by `RecordContainer.recordID(for:in:)`.
    ///
    /// Every stored property is a field of the same name. A relationship such as `var notes: [Note]` is a
    /// list of its records' names in order, never forward references, and each note is its own `CKRecord`.
    /// A child's `@Reference(to:action:)` is a `CKRecord.Reference` with that action. Lists of strings,
    /// numbers and dates are CloudKit lists, an asset is a `CKAsset`, and any other `Codable` value is its
    /// JSON as `Data`. Inverses and `@Timestamp(.synced)` aren't stored.
    ///
    /// Pass the server's last copy as `base`, such as one rebuilt from its encoded system fields, so the
    /// save carries its change tag. An asset whose file hasn't downloaded yet keeps the base's value.
    public func ckRecord(for change: RecordChangeData, in zoneID: CKRecordZone.ID, base: CKRecord? = nil) throws -> CKRecord? {
        guard let cloud = try cloudRecord(for: change) else { return nil }
        let record = base ?? CKRecord(recordType: cloud.type, recordID: Self.recordID(for: change.id, in: zoneID))
        cloud.fill(record)
        return record
    }

    /// The change a `CKRecord` from the server stands for, and the asset files it brought. Hand the files
    /// back from `downloadAsset(id:zone:into:)` when the container asks for them by ID.
    ///
    /// The record's `modificationDate` is its `synced` date. In a public zone its creator is its owner.
    public func change(from record: CKRecord, zone: Zone) throws -> (change: RecordChangeData, assets: [RecordAssetData]) {
        let store = try storage(for: zone).store
        guard let id = UUID(uuidString: record.recordID.recordName) else {
            throw RecordsError.incompatibleRecord(type: record.recordType, id: UUID())
        }
        var fields: [String: CloudValue] = [:]
        var assets: [RecordAssetData] = []
        for key in record.allKeys() {
            guard let value = record[key] else { continue }
            if let reference = value as? CKRecord.Reference {
                guard let target = UUID(uuidString: reference.recordID.recordName) else { continue }
                fields[key] = .reference(target, action: reference.action == .deleteSelf ? .deleteSelf : .none)
            } else if let asset = value as? CKAsset {
                guard let file = asset.fileURL else { continue }
                // Named by its contents, so every device and every download agree on the name.
                let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
                var name = digest.map { String(format: "%02x", $0) }.joined()
                let fileExtension = store.assetExtension(type: record.recordType, field: key)
                if !fileExtension.isEmpty { name += "." + fileExtension }
                fields[key] = .asset(URL(fileURLWithPath: name))
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
        let owner = publicZones.contains(zone) ? record.creatorUserRecordID?.recordName : nil
        let change = try store.change(
            from: CloudRecord(type: record.recordType, id: id, fields: fields), zone: zone, owner: owner, synced: record.modificationDate
        )
        return (change, assets)
    }

    /// The deletion a record the server reports deleted stands for, such as from
    /// `recordWithIDWasDeletedBlock`. Returns `nil` for a record name that isn't a record's ID.
    public func deletion(of recordID: CKRecord.ID, type: CKRecord.RecordType, zone: Zone, synced: Date? = nil) -> RecordChangeData? {
        guard let id = UUID(uuidString: recordID.recordName) else { return nil }
        return .delete(id: id, zone: zone, type: type, owner: nil, synced: synced)
    }

    /// The record ID a record's `id` has in a CloudKit zone: its `uuidString` as the record name.
    public static func recordID(for id: UUID, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }
}

extension CloudRecord {
    /// Writes these fields into `record` and clears the ones it no longer has. An asset whose file isn't
    /// there, such as one still downloading, keeps the record's value.
    func fill(_ record: CKRecord) {
        for key in record.allKeys() where fields[key] == nil {
            record.setObject(nil, forKey: key)
        }
        for (key, value) in fields {
            switch value {
            case .string(let value): record[key] = value
            case .int(let value): record[key] = value
            case .double(let value): record[key] = value
            case .date(let value): record[key] = value
            case .bytes(let value): record[key] = value
            case .strings(let value): record[key] = value
            case .ints(let value): record[key] = value
            case .doubles(let value): record[key] = value
            case .dates(let value): record[key] = value
            case .reference(let id, let action):
                record[key] = CKRecord.Reference(
                    recordID: RecordContainer.recordID(for: id, in: record.recordID.zoneID),
                    action: action == .deleteSelf ? .deleteSelf : CKRecord.ReferenceAction.none
                )
            case .asset(let file):
                if FileManager.default.fileExists(atPath: file.path) {
                    record[key] = CKAsset(fileURL: file)
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
/// Fields map as they do when the container syncs. Every stored property is a field of the same name. A
/// relationship such as `var steps: [Step]` is a list of the steps' record names in order, and each step is
/// its own `CKRecord`, so encode it separately. A child's `@Reference(to:action:)` is a `CKRecord.Reference`
/// with that action. Lists of strings, numbers and dates are CloudKit lists, an asset is a `CKAsset`, and any
/// other `Codable` value is its JSON as `Data`. Inverses and `@Timestamp(.synced)` aren't stored.
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
        let cloud = try RecordStore.cloudRecord(of: record)
        let ckRecord: CKRecord
        if let systemFields {
            ckRecord = try Self.record(fromSystemFields: systemFields, type: cloud.type, id: record.id, zoneID: zoneID)
        } else {
            ckRecord = CKRecord(recordType: cloud.type, recordID: RecordContainer.recordID(for: record.id, in: zoneID))
        }
        cloud.fill(ckRecord)
        return ckRecord
    }

    /// The server's last copy, rebuilt from its archived system fields, if they belong to this record. The
    /// zone's owner isn't compared, since a shared zone's records name their real owner.
    private static func record(fromSystemFields data: Data, type: String, id: UUID, zoneID: CKRecordZone.ID) throws -> CKRecord {
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
