import Foundation
@testable import SwiftRecords
import Versioning

extension RecordContainer {
    /// An in-memory container with `types` registered. Opening one in memory cannot fail.
    static func inMemory(_ types: [any Codable.Type]) -> RecordContainer {
        try! RecordContainer(for: types, storage: .inMemory)
    }

    /// An in-memory container with each of the given types registered.
    static func inMemory(_ type: any Codable.Type, _ others: any Codable.Type...) -> RecordContainer {
        inMemory([type] + others)
    }
}

/// Lookups by a record's name alone, for tests that keep each record in one zone. A row's
/// key is its name and its zone, so these find the zone first. Tests with the same record
/// in two zones use the row's full key instead.
extension RecordContainer {
    /// The key of the one row named `id`, in whichever zone holds it, or `nil` when there is none.
    func rowID(_ id: String) -> RowID? {
        let zones = (try? zones()) ?? []
        let found = zones.map { RowID(name: id, zone: $0) }.filter { key in
            // A row that cannot be read still exists, so its error reaches the test.
            do { return try row(id: key) != nil } catch { return true }
        }
        precondition(found.count <= 1, "\(id) is in more than one zone, so a test must name its zone.")
        return found.first
    }

    func row(id: String) throws(DatabaseError) -> Row? {
        guard let key = rowID(id) else { return nil }
        return try row(id: key)
    }

    func update(id: String, _ change: (inout Row) -> Void) throws(DatabaseError) {
        guard let key = rowID(id) else { return }
        try update(id: key, change)
    }

    func delete(id: String) throws(DatabaseError) {
        guard let key = rowID(id) else { return }
        try delete(id: key)
    }

    func save(deleted id: String) throws(DatabaseError) {
        guard let key = rowID(id) else { return }
        try save(deleted: key)
    }

    func delete<Record: Encodable & Identifiable>(our record: Record) throws where Record.ID: Encodable {
        try delete(our: record, id: \.id)
    }

    func delete<Record: Encodable, ID: Encodable>(our record: Record, id: KeyPath<Record, ID>) throws {
        try delete(id: Self.recordName(for: record[keyPath: id], type: Self.recordType(of: Record.self)))
    }

    /// The asset folder of the row named `id`, in whichever zone has one, so a test can also
    /// check that a removed row's folder is gone.
    func assetFolder(id: String) -> URL {
        if let key = rowID(id) { return assetFolder(id: key) }
        let zones = (try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)) ?? []
        let folders = zones.map { $0.appendingPathComponent(id, isDirectory: true) }
        return folders.first { FileManager.default.fileExists(atPath: $0.path) } ?? assets.appendingPathComponent(id, isDirectory: true)
    }

    func row(id: UUID) throws(DatabaseError) -> Row? { try row(id: id.uuidString) }
    func update(id: UUID, _ change: (inout Row) -> Void) throws(DatabaseError) { try update(id: id.uuidString, change) }
    func delete(id: UUID) throws(DatabaseError) { try delete(id: id.uuidString) }
    func save(deleted id: UUID) throws(DatabaseError) { try save(deleted: id.uuidString) }
    func assetFolder(id: UUID) -> URL { assetFolder(id: id.uuidString) }
}

#if canImport(CloudKit)
import CloudKit

extension RecordContainer {
    func send(id: UUID) throws(DatabaseError) -> CKRecord? {
        guard let key = rowID(id.uuidString) else { return nil }
        return try send(id: key)
    }

    func send(deleted id: UUID) throws(DatabaseError) -> CKRecord.ID? {
        guard let key = rowID(id.uuidString) else { return nil }
        return try send(deleted: key)
    }
}
#endif

extension RecordID {
    /// The id of the record named by the `UUID` `name`, as a `UUID` id names its record.
    init(name: UUID, zone: Zone) {
        self.init(name: name.uuidString, zone: zone)
    }
}

extension RecordContainer {
    /// Saves the server's version of the record named by the `UUID` `id`.
    func save(their json: JSONRepresentation, id: UUID, zone: Zone, type: String, metadata: Data?) throws(DatabaseError) {
        try save(their: json, id: id.uuidString, zone: zone, type: type, metadata: metadata)
    }
}
