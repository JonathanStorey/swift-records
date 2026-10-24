import Foundation
import SwiftRecords

/// A sync server in memory, so sync timings measure the local database rather than a network or files.
/// Each upload and download costs a dictionary lookup per record.
final class BenchmarkServer: SyncProvider, @unchecked Sendable {
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

    var isOnline: Bool {
        get { lock.withLock { online } }
        set { lock.withLock { online = newValue } }
    }

    var count: Int { lock.withLock { latest.values.filter { !$0.change.isDeletion }.count } }

    private func check() throws {
        guard isOnline else { throw SyncError.offline }
    }

    func userID() async throws -> String? {
        try check()
        return "benchmark"
    }

    func uploadRecordChanges(_ changes: [RecordChangeData]) async throws -> [UploadResult] {
        try check()
        return lock.withLock {
            changes.map { change in
                let key = "\(change.zone)|\(change.type)|\(change.id)"
                if !change.isDeletion, let current = latest[key]?.change, current.synced != change.synced {
                    return .conflict(current)
                }
                let sequence = log.count + 1
                let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
                latest[key] = (change.syncing(at: date), sequence)
                log.append((key, sequence))
                return .synced(id: change.id, at: date)
            }
        }
    }

    func downloadRecordChanges(in zone: Zone, after cursor: Data?) async throws -> RecordDownload {
        try check()
        return lock.withLock {
            var position = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            var changes: [RecordChangeData] = []
            while position < log.count, changes.count < pageSize {
                let entry = log[position]
                position += 1
                if let stored = latest[entry.key], stored.sequence == entry.sequence, stored.change.zone == zone {
                    changes.append(stored.change)
                }
            }
            return RecordDownload(changes: changes, cursor: Data(String(position).utf8), hasMore: position < log.count)
        }
    }

    func uploadAssets(_ assets: [RecordAssetData]) async throws {}

    func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL {
        throw SyncError.offline
    }
}
