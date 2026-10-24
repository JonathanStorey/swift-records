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
        for key in record.allKeys() where cloud.fields[key] == nil {
            record.setObject(nil, forKey: key)
        }
        for (key, value) in cloud.fields {
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
                    recordID: Self.recordID(for: id, in: record.recordID.zoneID),
                    action: action == .deleteSelf ? .deleteSelf : CKRecord.ReferenceAction.none
                )
            case .asset(let file):
                if FileManager.default.fileExists(atPath: file.path) {
                    record[key] = CKAsset(fileURL: file)
                }
            }
        }
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
#endif
