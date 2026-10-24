#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

extension RecordContainer {
    /// The `CKRecord` a save becomes, or `nil` for a deletion, which you delete by `RecordContainer.recordID(for:in:)`.
    ///
    /// Each field is copied as it is: a `RecordValue` is already what CloudKit stores. A relationship such as
    /// `var notes: [Note]` is a list of its records' names in order, never forward references, and each note
    /// is its own `CKRecord`. A child's `@Reference(to:action:)` is a `CKRecord.Reference` with that action,
    /// and an asset is a `CKAsset` of its file here.
    ///
    /// A change with a `changeTag` saves as an update of the server's copy. The record is built on the
    /// copy's archived system fields when the metadata has them, as it does for a change that came from
    /// CloudKit, and otherwise on system fields written from the metadata itself. An asset whose file
    /// hasn't downloaded yet is left out.
    public func ckRecord(for change: RecordChangeData, in zoneID: CKRecordZone.ID) throws -> CKRecord? {
        guard let fields = change.fields else { return nil }
        let store = try storage(for: change.zone).store
        let record = try change.metadata.systemFields.map {
            try CKRecordEncoder.record(fromSystemFields: $0, type: change.type, id: change.id, zoneID: zoneID)
        } ?? CKRecordEncoder.record(from: change.metadata, type: change.type, id: change.id, zoneID: zoneID)
            ?? CKRecord(recordType: change.type, recordID: Self.recordID(for: change.id, in: zoneID))
        record.fill(fields) { store.assetURL(named: $0) }
        return record
    }

    /// The change a `CKRecord` from the server stands for, and the asset files it brought. Hand the files
    /// back from `downloadAsset(id:zone:into:)` when the container asks for them by ID.
    ///
    /// Its system fields become the change's metadata: `recordChangeTag`, `creationDate`, `modificationDate`
    /// and the creator's and last modifier's record names, with the archived system fields kept beside them
    /// so the next upload builds on exactly the server's copy. In a public zone the creator is the owner.
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
                fields[key] = .reference(target, action: reference.action == .deleteSelf ? .deleteSelf : .none)
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
        let metadata = SyncMetadata(
            changeTag: record.recordChangeTag, created: record.creationDate, modified: record.modificationDate,
            creator: record.creatorUserRecordID?.recordName, lastModifier: record.lastModifiedUserRecordID?.recordName,
            systemFields: Self.systemFields(of: record)
        )
        return (RecordChangeData(id: id, zone: zone, type: record.recordType, fields: fields, metadata: metadata), assets)
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

    /// A server copy rebuilt from readable metadata, by writing its system fields under the keys CloudKit's
    /// own archive uses. `nil` when the metadata has no change tag, since the record is then new, or when
    /// the archive doesn't read back with the tag, as it wouldn't if CloudKit changed its format.
    static func record(from metadata: SyncMetadata, type: String, id: UUID, zoneID: CKRecordZone.ID) -> CKRecord? {
        guard let changeTag = metadata.changeTag else { return nil }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.encode(type, forKey: "RecordType")
        coder.encode(RecordContainer.recordID(for: id, in: zoneID), forKey: "RecordID")
        coder.encode(changeTag, forKey: "ETag")
        coder.encode(true, forKey: "KnownToServer")
        if let created = metadata.created { coder.encode(created as NSDate, forKey: "RecordCtime") }
        if let modified = metadata.modified { coder.encode(modified as NSDate, forKey: "RecordMtime") }
        if let creator = metadata.creator { coder.encode(CKRecord.ID(recordName: creator), forKey: "CreatorUserRecordID") }
        if let modifier = metadata.lastModifier {
            coder.encode(CKRecord.ID(recordName: modifier), forKey: "LastModifiedUserRecordID")
        }
        coder.finishEncoding()
        guard let decoder = try? NSKeyedUnarchiver(forReadingFrom: coder.encodedData) else { return nil }
        decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        guard let record = CKRecord(coder: decoder), record.recordChangeTag == changeTag else { return nil }
        return record
    }
}
#endif
