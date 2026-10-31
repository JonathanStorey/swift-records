#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation
import SwiftRecords

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
    ///
    /// A change that names its `changedKeys` sets only those fields and clears its `clearedKeys`, so CloudKit
    /// uploads nothing else. The record still carries the change tag, so a stale copy fails as a conflict.
    public func ckRecord(for change: RecordChangeData, in zoneID: CKRecordZone.ID) throws -> CKRecord? {
        guard let fields = change.fields else { return nil }
        let zone = change.zone
        let record = try change.tag.map {
            try Self.record(fromSystemFields: $0, type: change.type, id: change.id, zoneID: zoneID)
        } ?? CKRecord(recordType: change.type, recordID: Self.recordID(for: change.id, in: zoneID))
        let file = { [self] (id: String) in change.assetFiles[id] ?? (try? self.assetURL(named: id, in: zone)) }
        if change.tag != nil, let changedKeys = change.changedKeys {
            record.fill(fields, only: changedKeys, clearing: change.clearedKeys, file: file)
        } else {
            record.fill(fields, file: file)
        }
        return record
    }

    /// The change a `CKRecord` from the server stands for, and the asset files it brought. Hand the files
    /// back from `downloadAsset(id:zone:into:)` when the container asks for them by ID.
    ///
    /// The record's archived system fields become the change's `tag`, so the next upload builds on exactly
    /// the server's copy, and its `modificationDate` is the `synced` date.
    public func change(from record: CKRecord, zone: Zone) throws -> (change: RecordChangeData, assets: [RecordAssetData]) {
        guard let id = UUID(uuidString: record.recordID.recordName) else {
            throw RecordsError.incompatibleRecord(type: record.recordType, id: UUID())
        }
        var fields: [String: RecordValue] = [:]
        var assets: [RecordAssetData] = []
        for key in record.allKeys() {
            guard let value = record[key] else { continue }
            // An asset's ID rides beside it, so a download needn't hash the file again.
            if key.hasSuffix(CKRecord.assetIDSuffix) {
                let base = String(key.dropLast(CKRecord.assetIDSuffix.count))
                if record[base] == nil || record[base] is CKAsset { continue }
            }
            if let reference = value as? CKRecord.Reference {
                guard let target = UUID(uuidString: reference.recordID.recordName) else { continue }
                fields[key] = .reference(target, action: reference.action == .deleteSelf ? .deleteSelf : .nullify)
            } else if let asset = value as? CKAsset {
                guard let file = asset.fileURL else { continue }
                // Named by its contents, so every device and every download agree on the name.
                var name: String
                if let id = record[key + CKRecord.assetIDSuffix] as? String, Self.isAssetID(id) {
                    name = id
                } else {
                    let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
                    name = digest.map { String(format: "%02x", $0) }.joined()
                    let fileExtension = try assetExtension(type: record.recordType, field: key, in: zone)
                    if !fileExtension.isEmpty { name += "." + fileExtension }
                }
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
            id: id, zone: zone, type: record.recordType, fields: fields, tag: Self.systemFields(of: record), synced: record.modificationDate,
            assetFiles: Dictionary(assets.map { ($0.id, $0.file) }, uniquingKeysWith: { first, _ in first })
        )
        return (change, assets)
    }

    /// Whether a name is one SwiftRecords gives an asset: a SHA-256 in hex, and maybe an extension. Anything
    /// else, such as a path, is hashed again rather than trusted as a file name.
    private static func isAssetID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let hex = Set("0123456789abcdef")
        guard parts[0].count == 64, parts[0].allSatisfy(hex.contains) else { return false }
        return parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy { $0.isLetter || $0.isNumber })
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
    public static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
}

extension CKRecord {
    /// The suffix of the field beside each asset that holds its ID.
    static let assetIDSuffix = "_assetID"
    /// Writes these values and clears the fields it no longer has. `file` finds an asset's file by its ID,
    /// and an asset whose file isn't there, such as one still downloading, keeps the record's value.
    func fill(_ values: [String: RecordValue], file: (String) -> URL?) {
        for key in allKeys() where values[key] == nil {
            setObject(nil, forKey: key)
        }
        fill(values, only: Set(values.keys), clearing: [], file: file)
    }

    /// Writes only the `keys` among these values and clears `cleared`, so CloudKit sends nothing else.
    func fill(_ values: [String: RecordValue], only keys: Set<String>, clearing cleared: Set<String>, file: (String) -> URL?) {
        for key in cleared {
            // A cleared asset's ID field stays, and is ignored without its asset.
            setObject(nil, forKey: key)
        }
        // The record belongs to what its first `.deleteSelf` pointer names, which is how sharing finds it.
        let parent = values.keys.sorted().lazy.compactMap { key -> CKRecord.Reference? in
            guard case .reference(let id, .deleteSelf)? = values[key] else { return nil }
            return CKRecord.Reference(recordID: RecordContainer.recordID(for: id, in: self.recordID.zoneID), action: .none)
        }.first
        if self.parent?.recordID != parent?.recordID {
            self.parent = parent
        }
        for (key, value) in values where keys.contains(key) {
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
                    self[key + Self.assetIDSuffix] = id
                }
            }
        }
    }
}

extension RecordContainer {
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
