import Foundation
@testable import SwiftRecords
import Versioning

extension RecordContainer {
    /// An in-memory container with `types` registered. Opening one in memory cannot fail.
    static func inMemory(_ types: [any (Codable & Mergeable).Type]) -> RecordContainer {
        try! RecordContainer(for: types, storage: .inMemory)
    }

    /// An in-memory container with each of the given types registered.
    static func inMemory(_ type: any (Codable & Mergeable).Type, _ others: any (Codable & Mergeable).Type...) -> RecordContainer {
        inMemory([type] + others)
    }
}

/// Lookups by a record's name alone, for tests that keep each record in one zone. A row's
/// key is its name and its zone, so these find the zone first. Tests with the same record
/// in two zones use the row's full key instead.
extension RecordContainer {
    /// The key of the one row named `id`, in whichever zone holds it, or `nil` when there is none.
    func rowID(_ id: UUID) -> RowID? {
        let zones = (try? zones()) ?? []
        let found = zones.map { RowID(name: id, zone: $0) }.filter { key in
            // A row that cannot be read still exists, so its error reaches the test.
            do { return try row(id: key) != nil } catch { return true }
        }
        precondition(found.count <= 1, "\(id) is in more than one zone, so a test must name its zone.")
        return found.first
    }

    func row(id: UUID) throws(DatabaseError) -> Row? {
        guard let key = rowID(id) else { return nil }
        return try row(id: key)
    }

    func update(id: UUID, _ change: (inout Row) -> Void) throws(DatabaseError) {
        guard let key = rowID(id) else { return }
        try update(id: key, change)
    }

    func delete(id: UUID) throws(DatabaseError) {
        guard let key = rowID(id) else { return }
        try delete(id: key)
    }

    func save(deleted id: UUID) throws(DatabaseError) {
        guard let key = rowID(id) else { return }
        try save(deleted: key)
    }

    func delete<Record: Encodable & Identifiable>(our record: Record) throws where Record.ID: Encodable {
        try delete(our: record, id: \.id)
    }

    func delete<Record: Encodable, ID: Encodable>(our record: Record, id: KeyPath<Record, ID>) throws {
        try delete(id: Self.recordID(for: record[keyPath: id], type: Self.recordType(of: Record.self)))
    }

    /// The asset folder of the row named `id`, in whichever zone has one, so a test can also
    /// check that a removed row's folder is gone.
    func assetFolder(id: UUID) -> URL {
        if let key = rowID(id) { return assetFolder(id: key) }
        let zones = (try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)) ?? []
        let folders = zones.map { $0.appendingPathComponent(id.uuidString, isDirectory: true) }
        return folders.first { FileManager.default.fileExists(atPath: $0.path) } ?? assets.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

#if canImport(CloudKit)
import CloudKit

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension RecordContainer {
    func send(id: UUID) throws(DatabaseError) -> CKRecord? {
        guard let key = rowID(id) else { return nil }
        return try send(id: key)
    }

    func send(deleted id: UUID) throws(DatabaseError) -> CKRecord.ID? {
        guard let key = rowID(id) else { return nil }
        return try send(deleted: key)
    }
}
#endif
