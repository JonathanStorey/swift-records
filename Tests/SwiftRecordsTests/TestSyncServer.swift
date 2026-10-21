import Foundation
import SwiftRecords

/// A stand-in sync server that several in-memory containers share, each playing one device. It checks
/// tags the way CloudKit does: a save whose tag isn't the server's latest comes back as a conflict.
final class TestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: SyncRecord] = [:]
    private var versions: [String: Int] = [:]
    /// The sequence number of each record's latest change, deletions included.
    private var changed: [String: Int] = [:]
    private var sequence = 0

    var account: String? = "alice"
    var isOnline = true
    var isFull = false
    var rejectedTypes: Set<String> = []

    enum SaveResult {
        case saved(SyncRecord)
        case conflict(SyncRecord)
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func key(_ type: String, _ id: UUID) -> String { "\(type)|\(id)" }

    private static func tag(_ version: Int) -> Data { Data("v\(version)".utf8) }

    func save(_ record: SyncRecord) -> SaveResult {
        withLock {
            let key = Self.key(record.type, record.id)
            let current = versions[key]
            if !record.isDeletion {
                if let current, record.tag != Self.tag(current) {
                    return .conflict(records[key] ?? SyncRecord(type: record.type, id: record.id, fields: nil))
                }
                // A tag for a record the server deleted: the deletion is the server's newer copy.
                if current == nil, record.tag != nil, changed[key] != nil {
                    return .conflict(SyncRecord(type: record.type, id: record.id, fields: nil))
                }
            }
            sequence += 1
            changed[key] = sequence
            guard !record.isDeletion else {
                records[key] = nil
                versions[key] = nil
                return .saved(record)
            }
            let version = (current ?? 0) + 1
            var stored = record
            stored.tag = Self.tag(version)
            records[key] = stored
            versions[key] = version
            return .saved(stored)
        }
    }

    /// Each record's latest change after `cursor`, and the new cursor.
    func changes(since cursor: Int) -> ([SyncRecord], Int) {
        withLock {
            let keys = changed.filter { $0.value > cursor }.sorted { $0.value < $1.value }.map(\.key)
            let changes = keys.map { key -> SyncRecord in
                if let record = records[key] { return record }
                let parts = key.split(separator: "|")
                return SyncRecord(type: String(parts[0]), id: UUID(uuidString: String(parts[1]))!, fields: nil)
            }
            return (changes, sequence)
        }
    }

    func record(_ type: String, _ id: UUID) -> SyncRecord? {
        withLock { records[Self.key(type, id)] }
    }

    var count: Int { withLock { records.count } }

    /// Deletes the whole zone, as when a person deletes the app's data in Settings.
    func reset() {
        withLock {
            records = [:]
            versions = [:]
            changed = [:]
        }
    }
}

/// A provider that talks to a `TestServer`.
final class TestProvider: SyncProvider, @unchecked Sendable {
    let server: TestServer
    private let lock = NSLock()
    private var report: (@Sendable (SyncEvent) async -> Void)?
    private var cursor = 0
    private var batches: [[SyncRecord]] = []
    /// Saves on the server without reporting `.sent`, as if the app quit before hearing back.
    var dropsAcknowledgements = false

    init(server: TestServer) {
        self.server = server
    }

    /// Every batch the container asked to send.
    var sentBatches: [[SyncRecord]] { lock.withLock { batches } }

    func open(state: Data?, report: @escaping @Sendable (SyncEvent) async -> Void) async {
        lock.withLock {
            self.report = report
            cursor = state.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        }
        await report(.accountChanged(server.withLock { server.account }))
    }

    func send(_ records: [SyncRecord]) async {
        lock.withLock { batches.append(records) }
        let (online, full, rejected) = server.withLock { (server.isOnline, server.isFull, server.rejectedTypes) }
        guard online else { return await emit(.notSent(records, because: .unreachable)) }
        guard !full else { return await emit(.notSent(records, because: .storageFull)) }
        var sent: [SyncRecord] = []
        var conflicts: [SyncRecord] = []
        var refused: [SyncRecord] = []
        for record in records {
            if rejected.contains(record.type) {
                refused.append(record)
                continue
            }
            switch server.save(record) {
            case .saved(let stored): sent.append(stored)
            case .conflict(let copy): conflicts.append(copy)
            }
        }
        if !sent.isEmpty, !dropsAcknowledgements {
            await emit(.sent(sent, state: nil))
        }
        if !conflicts.isEmpty {
            await emit(.received(conflicts, state: nil))
        }
        if !refused.isEmpty {
            await emit(.notSent(refused, because: .rejected))
        }
    }

    func fetch() async {
        guard server.withLock({ server.isOnline }) else { return }
        let (changes, cursor) = server.changes(since: lock.withLock { self.cursor })
        lock.withLock { self.cursor = cursor }
        await emit(.received(changes, state: Data(String(cursor).utf8)))
    }

    /// Reports an event as if the server had caused it.
    func emit(_ event: SyncEvent) async {
        guard let report = lock.withLock({ report }) else { return }
        await report(event)
    }
}
