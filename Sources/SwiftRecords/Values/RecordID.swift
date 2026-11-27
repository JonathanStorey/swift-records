import Foundation

/// Where a record of type `Record` lives: its name and its ``Zone``. It is
/// everything needed to find the record again.
///
/// ```swift
/// let folder = try RecordID(folder, zone: "Notes")          // an Identifiable folder
/// let page = try RecordID(page, id: \.slug, zone: "Pages")   // a plain struct
/// ```
///
/// The record type is `Record` itself, so it is not stored. The name is the record's `UUID`
/// id as it is, or, for any other id, the record type and the id, as in `"Page:intro"`, the
/// same name the record is saved under. The zone is as this device sees it, so its
/// ``Zone/database`` says where to fetch it.
public struct RecordID<Record>: Hashable, Codable, Sendable {
    /// The record's name in CloudKit.
    public var name: String
    public var zone: Zone

    public init(name: String, zone: Zone) {
        self.name = name
        self.zone = zone
    }
}

extension RecordID {
    /// The id of `record`, identified by the property at `id`.
    public init<ID: Encodable>(_ record: Record, id: KeyPath<Record, ID>, zone: Zone) throws {
        try self.init(Record.self, id: record[keyPath: id], zone: zone)
    }

    /// The id of an `Identifiable` `record`.
    public init(_ record: Record, zone: Zone) throws where Record: Identifiable, Record.ID: Encodable {
        try self.init(record, id: \.id, zone: zone)
    }
}

extension RecordID {
    /// The id of the record of type `type` with the id `id` in `zone`, named by
    /// ``RecordContainer/recordName(for:type:checkingLength:)``, which throws when the name is
    /// longer than CloudKit allows, unless `checkingLength` is `false`.
    init<Value>(_ type: Value.Type, id: some Encodable, zone: Zone, checkingLength: Bool = true) throws {
        let name = try RecordContainer.recordName(for: id, type: RecordContainer.recordType(of: type), checkingLength: checkingLength)
        self.init(name: name, zone: zone)
    }
}
