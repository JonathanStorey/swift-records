import Foundation
import Versioning
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// The database that holds records: a single SQLite connection, and nothing else.
///
/// A container is created for the record types it holds. `RecordContainer(for:)` stores the
/// database in `default.records` in Application Support, and
/// `RecordContainer(for:storage: .inMemory)` keeps it in memory.
public final class RecordContainer: @unchecked Sendable {
    /// The database file, or `nil` when the container is in memory.
    let url: URL?

    // Opened with SQLITE_OPEN_FULLMUTEX, so SQLite serializes every call on it.
    let connection: OpaquePointer
    // Serializes registering, a read of a row with the write that follows it, and a
    // transaction with the saves inside it, which take the lock again.
    private let lock = NSRecursiveLock()
    /// The folder holding each row's asset files: beside the database file, or, in memory,
    /// a new folder in the temporary directory, removed with the container.
    let assets: URL
    /// The registered record types, by record type name. Read and written while locked.
    var registrations: [String: RecordType] = [String(describing: Relationship.self): Relationship.self]
    /// The side kept at the values that still conflict after a record type's own merge,
    /// stored under the lock. See ``favoring``.
    private var storedFavoring: KeepMerge<JSONRepresentation> = .ours

    /// The side kept at each value that still conflicts after a record type's own merge, so
    /// a merge never stops syncing.
    ///
    /// The type's own merge runs first, so each `Mergeable` property still merges by its own
    /// rules, and only what that cannot settle takes a side. The default, `.ours`, keeps this
    /// device's value at each conflicting field and merges everything else, the
    /// field-by-field "local edit wins" of Apple's CloudKit samples. `.theirs` keeps the server's.
    ///
    /// ```swift
    /// container.favoring = .theirs
    /// ```
    var favoring: KeepMerge<JSONRepresentation> {
        get { locked { storedFavoring } }
        set { locked { storedFavoring = newValue } }
    }

    /// The rows whose unused asset files wait for the transaction around them to end, or
    /// `nil` outside a transaction. Read and written while locked, only by `transaction(_:)`
    /// and `sweepAssets`.
    private var assetsToSweep: Set<RowID>?
    /// The changes the open transaction made, or `nil` outside one. Read and written while
    /// locked, only by `transaction(author:_:)` and `log(_:)`.
    private var transactionChanges: [RecordTransaction.Change]?
    /// The id of the last ``RecordTransaction`` reported. Read and written while locked.
    private var transactionCount: Int64 = 0
    /// Each live ``transactions()`` stream, by a key its termination removes. Read and written while locked.
    var listeners: [UUID: AsyncStream<RecordTransaction>.Continuation] = [:]

    /// An empty container held in memory, with no record types registered.
    convenience init() {
        do {
            try self.init(path: ":memory:", url: nil)
        } catch {
            fatalError("SQLite could not open an in-memory database: \(error)")
        }
    }

    /// A container stored in the file at `url`, created if it does not exist, with no record
    /// types registered.
    convenience init(url: URL) throws(DatabaseError) {
        try self.init(path: url.path, url: url)
    }

    private init(path: String, url: URL?) throws(DatabaseError) {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &connection, flags, nil)
        guard code == SQLITE_OK, let connection else {
            let error = DatabaseError(code: code, connection: connection)
            sqlite3_close_v2(connection)
            throw error
        }
        self.connection = connection
        self.url = url
        assets = url.map { $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + ".assets", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // WAL lets a read run beside a write and makes each commit cheaper.
        try execute("PRAGMA journal_mode = WAL")
        try execute(Self.createTable)
    }

    deinit {
        sqlite3_close_v2(connection)
        if url == nil { try? FileManager.default.removeItem(at: assets) }
    }
}

/// An error SQLite reported, with its result code and message.
public struct DatabaseError: Error, Equatable, CustomStringConvertible {
    /// The SQLite result code, such as `SQLITE_CANTOPEN` (14).
    let code: Int32
    public let description: String
}

extension DatabaseError {
    init(code: Int32, connection: OpaquePointer?) {
        let message = connection.flatMap { sqlite3_errmsg($0) } ?? sqlite3_errstr(code)
        self.init(code: code, description: message.map { String(cString: $0) } ?? "SQLite error \(code)")
    }
}

extension RecordContainer {
    /// The author of the changes the sync engine saves.
    static let syncAuthor = "sync"

    /// The database file: `default.records` in Application Support, or in the Application
    /// Support folder of `appGroup`'s shared container. The folder is created if needed.
    static func storeURL(appGroup: String?) throws(DatabaseError) -> URL {
        let folder: URL
        if let appGroup {
            #if canImport(Darwin)
            guard let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
                throw DatabaseError(code: SQLITE_CANTOPEN, description: "The app group \(appGroup) has no shared container. Check the app's entitlements.")
            }
            folder = shared.appendingPathComponent("Library/Application Support", isDirectory: true)
            #else
            throw DatabaseError(code: SQLITE_CANTOPEN, description: "App groups exist only on Apple platforms.")
            #endif
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw DatabaseError(code: SQLITE_CANTOPEN, description: "Could not create \(folder.path): \(error.localizedDescription)")
        }
        return folder.appendingPathComponent("default.records")
    }

    /// The result of `body`, with no other locked work on the container running at the same time.
    func locked<T, Failure: Error>(_ body: () throws(Failure) -> T) throws(Failure) -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The result of `body`, run as one SQLite transaction: every write in it commits
    /// together, or, when it throws, none does.
    ///
    /// Every write to the `record` table runs in one. Once it commits, the changes it made
    /// go to every ``transactions()`` stream as one ``RecordTransaction`` by `author`. A
    /// rollback drops them. Inside another transaction, `body` joins it, and the outer
    /// transaction's `author` stands.
    ///
    /// Asset files no longer used are removed only once it ends, so a rolled-back row
    /// still finds its files, and files copied in for rows that never landed are removed.
    func transaction<T>(author: String? = nil, _ body: () throws(DatabaseError) -> T) throws(DatabaseError) -> T {
        try locked { () throws(DatabaseError) -> T in
            guard sqlite3_get_autocommit(connection) != 0 else { return try body() }
            assetsToSweep = []
            transactionChanges = []
            defer {
                transactionChanges = nil
                let ids = assetsToSweep ?? []
                assetsToSweep = nil
                for id in ids {
                    // A row that cannot be read keeps its files.
                    do {
                        if let row = try row(id: id) { sweepAssets(of: row) } else { sweepAssets(id: id) }
                    } catch {}
                }
            }
            try execute("BEGIN IMMEDIATE")
            do throws(DatabaseError) {
                let result = try body()
                try execute("COMMIT")
                report(transactionChanges ?? [], author: author)
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// A stream of every transaction this container commits from now on, one element per
    /// transaction, in commit order. It ends when the task reading it is cancelled.
    ///
    /// Another process sharing the database, such as a widget, does not appear here.
    ///
    /// ```swift
    /// for await transaction in container.transactions() where transaction.author != "sync" {
    ///     print(transaction.changes.map(\.id))
    /// }
    /// ```
    public func transactions() -> AsyncStream<RecordTransaction> {
        let (stream, continuation) = AsyncStream<RecordTransaction>.makeStream()
        let key = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.locked { self?.listeners[key] = nil }
        }
        locked { listeners[key] = continuation }
        return stream
    }

    /// Adds `change` to the open transaction's changes. Runs while locked, inside a transaction.
    func log(_ change: RecordTransaction.Change) {
        transactionChanges?.append(change)
    }

    /// Hands `changes`, which a transaction by `author` just committed, to every
    /// ``transactions()`` stream as one ``RecordTransaction``. Runs while locked.
    private func report(_ changes: [RecordTransaction.Change], author: String?) {
        guard !changes.isEmpty else { return }
        transactionCount += 1
        let transaction = RecordTransaction(id: transactionCount, author: author, timestamp: Date(), changes: changes)
        for listener in listeners.values { listener.yield(transaction) }
    }

    /// Removes each file in the folder of `row` that none of its `base`, `ours`, `theirs`
    /// and `sent` points at, and the folder once nothing is left in it: now, or, inside a
    /// transaction, once it ends, so a rolled-back write still finds its files.
    func sweepAssets(of row: Row) {
        guard assetsToSweep == nil else { assetsToSweep?.insert(row.rowID); return }
        let folder = assetFolder(id: row.rowID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let used = Set([row.base, row.ours, row.theirs, row.sent].compactMap { $0 }.flatMap(\.strings).compactMap { text in
            text.hasPrefix(folder.absoluteString) ? URL(string: text)?.lastPathComponent : nil
        })
        let unused = files.filter { !used.contains($0.lastPathComponent) }
        for file in unused { try? FileManager.default.removeItem(at: file) }
        if unused.count == files.count { try? FileManager.default.removeItem(at: folder) }
    }

    /// Removes the folder of the removed row `id` and every file in it: now, or, inside a
    /// transaction, once it ends, so a rolled-back removal still finds its files.
    func sweepAssets(id: RowID) {
        guard assetsToSweep == nil else { assetsToSweep?.insert(id); return }
        try? FileManager.default.removeItem(at: assetFolder(id: id))
    }

    /// Runs one or more SQL statements that return no rows.
    func execute(_ sql: String) throws(DatabaseError) {
        let code = sqlite3_exec(connection, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw DatabaseError(code: code, connection: connection) }
    }
}

private extension JSONRepresentation {
    /// Every string in this value, at any depth.
    var strings: [String] {
        switch self {
        case .string(let text): [text]
        case .array(let elements): elements.flatMap(\.strings)
        case .object(let pairs): pairs.flatMap { $0.value.strings }
        default: []
        }
    }
}
