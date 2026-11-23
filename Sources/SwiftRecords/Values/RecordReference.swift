import Foundation
import Versioning
/// A reference to another record in the same zone, as CloudKit's
/// `CKRecord.Reference` stores it, with the zone as this device sees it.
///
/// CloudKit requires a reference to point into the zone of the record
/// that holds it, so a record encoder writes only the name and a record
/// decoder fills in the zone and owner from the record it reads. JSON
/// keeps them, and the container fills them in when it saves a record.
public struct RecordReference: Codable, Hashable, Sendable {
    /// What CloudKit does to the record holding the reference when the
    /// target record is deleted. The cases match `CKRecord.ReferenceAction`.
    public enum Action: String, CaseIterable, Codable, Hashable, Sendable {
        /// Nothing. The reference is left pointing at a missing record.
        case none
        /// The record holding the reference is deleted too.
        case deleteSelf
    }

    /// The target record's name.
    public var recordName: String
    /// The target's zone, or `nil` when it is the holding record's zone.
    public var zone: String?
    /// The target zone's owner, or `nil` when it is the holding record's.
    public var owner: String?
    public var action: Action
    /// Whether the target is the record's `parent`, which CloudKit
    /// shares the record with. A parent's action is always `.none`.
    public var isParent: Bool

    public init(recordName: String, zone: String? = nil, owner: String? = nil, action: Action = .none) {
        self.recordName = recordName
        self.zone = zone
        self.owner = owner
        self.action = action
        isParent = false
    }

    /// A reference to the record's parent.
    public init(parent recordName: String, zone: String? = nil, owner: String? = nil) {
        self.recordName = recordName
        self.zone = zone
        self.owner = owner
        action = .none
        isParent = true
    }
}

// `zone` and `owner` are written only when known, and `isParent` only when it is
// true, so a missing flag decodes as `false`.
extension RecordReference {
    private enum CodingKeys: String, CodingKey {
        case recordName, zone, owner, action, isParent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordName = try container.decode(String.self, forKey: .recordName)
        zone = try container.decodeIfPresent(String.self, forKey: .zone)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        action = try container.decode(Action.self, forKey: .action)
        isParent = try container.decodeIfPresent(Bool.self, forKey: .isParent) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordName, forKey: .recordName)
        try container.encodeIfPresent(zone, forKey: .zone)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encode(action, forKey: .action)
        if isParent { try container.encode(true, forKey: .isParent) }
    }
}
