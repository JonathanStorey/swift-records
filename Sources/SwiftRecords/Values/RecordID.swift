import Foundation

/// Where a record of type `Record` lives: its name and its ``Zone``. It is
/// everything needed to find the record again, so it can be stored in a reference or handed
/// to a view.
///
/// ```swift
/// let folder = try RecordID(folder, zone: "Notes")          // an Identifiable folder
/// let page = try RecordID(page, id: \.slug, zone: "Pages")   // a plain struct
/// ```
///
/// The record type is `Record` itself, so it is not stored. The name is the record's `UUID`
/// id, or a stable hash of any other id, the same name the record is saved under. The
/// zone is as this device sees it, so its ``Zone/database`` says where to fetch it.
public struct RecordID<Record>: Hashable, Codable, Sendable {
    /// The record's name in CloudKit.
    public var name: UUID
    public var zone: Zone

    public init(name: UUID, zone: Zone) {
        self.name = name
        self.zone = zone
    }
}

extension RecordID {
    /// The id of `record`, identified by the property at `id`.
    public init<ID: Encodable>(_ record: Record, id: KeyPath<Record, ID>, zone: Zone) throws {
        let name = try RecordContainer.recordID(for: record[keyPath: id], type: RecordContainer.recordType(of: Record.self))
        self.init(name: name, zone: zone)
    }

    /// The id of an `Identifiable` `record`.
    public init(_ record: Record, zone: Zone) throws where Record: Identifiable, Record.ID: Encodable {
        try self.init(record, id: \.id, zone: zone)
    }
}
