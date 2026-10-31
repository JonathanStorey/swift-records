import Foundation
import SwiftRecords

/// A sync server in memory, so sync timings measure the local database rather than a network or files.
/// Each upload and download costs a dictionary lookup per record.
final class BenchmarkServer: SyncTransport, @unchecked Sendable {
    let identifier: String
    private let lock = NSLock()
    private var online = false
    /// Each record's latest change and the sequence number it was stored at.
    private var latest: [String: (change: RecordChangeData, sequence: Int)] = [:]
    /// Every change stored, in order. A download skips the ones a later change replaced.
    private var log: [(key: String, sequence: Int)] = []
    private let pageSize = 400

    init(name: String) {
        identifier = "BenchmarkServer.\(name)"
    }

    /// An engine for one device that syncs only when asked, so timings cover only the work they name.
    func makeEngine() -> PollingSyncEngine {
        PollingSyncEngine(transport: self, automaticallySync: false)
    }

    var isOnline: Bool {
        get { lock.withLock { online } }
        set { lock.withLock { online = newValue } }
    }

    var count: Int { lock.withLock { latest.values.filter { !$0.change.isDeletion }.count } }

    private func check() throws {
        guard isOnline else { throw SyncFailure.networkUnavailable }
    }

    func currentUser() async throws -> String? {
        try check()
        return "benchmark"
    }

    func modifyRecords(_ batch: RecordBatch) async throws -> SentRecordChanges {
        try check()
        return lock.withLock {
            var result = SentRecordChanges()
            for change in batch.changes {
                let key = "\(change.zone)|\(change.type)|\(change.id)"
                if !change.isDeletion, let current = latest[key]?.change, current.tag != change.tag {
                    result.failed.append(FailedSave(change: change, failure: .serverRecordChanged(current)))
                    continue
                }
                let sequence = log.count + 1
                var stored = change
                stored.tag = Data(String(sequence).utf8)
                stored.synced = Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
                latest[key] = (stored, sequence)
                log.append((key, sequence))
                if change.isDeletion {
                    result.deleted.append(RecordDeletion(id: change.id, zone: change.zone, type: change.type))
                } else {
                    result.saved.append(stored)
                }
            }
            return result
        }
    }

    func fetchDatabaseChanges(_ scope: Zone.Scope, since token: Data?) async throws -> DatabaseChanges {
        try check()
        let zones = lock.withLock { Set(latest.values.map(\.change.zone)) }
        return DatabaseChanges(modified: zones.sorted { $0.name < $1.name }, token: nil)
    }

    func fetchZoneChanges(_ zone: Zone, since token: Data?) async throws -> ZoneChanges {
        try check()
        return lock.withLock {
            var position = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            var saved: [RecordChangeData] = []
            var deleted: [RecordDeletion] = []
            while position < log.count, saved.count + deleted.count < pageSize {
                let entry = log[position]
                position += 1
                if let stored = latest[entry.key], stored.sequence == entry.sequence, stored.change.zone == zone {
                    if stored.change.isDeletion {
                        deleted.append(RecordDeletion(id: stored.change.id, zone: zone, type: stored.change.type))
                    } else {
                        saved.append(stored.change)
                    }
                }
            }
            return ZoneChanges(saved: saved, deleted: deleted, token: Data(String(position).utf8), moreComing: position < log.count)
        }
    }
}
