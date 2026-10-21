import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A value as SQLite stores it.
public enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin wrapper over one SQLite connection. Not thread-safe; `RecordContainer` serializes access.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var savepointDepth = 0
    /// Prepared statements by SQL, reused so repeated queries skip parsing. Cleared when it grows past
    /// `statementCacheLimit`, which batch queries with varying numbers of placeholders can cause.
    private var statements: [String: OpaquePointer] = [:]
    private let statementCacheLimit = 200

    init(url: URL?) throws {
        let path = url?.path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(handle)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        if statements.count >= statementCacheLimit {
            statements.values.forEach { sqlite3_finalize($0) }
            statements.removeAll()
        }
        statements[sql] = statement
        return statement
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    @discardableResult
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        let statement = try prepare(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }

        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, position)
            case .integer(let int): result = sqlite3_bind_int64(statement, position, int)
            case .real(let double): result = sqlite3_bind_double(statement, position, double)
            case .text(let text): result = sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
                }
            }
            guard result == SQLITE_OK else { throw lastError() }
        }

        var rows: [[String: SQLiteValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: SQLiteValue] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    row[name] = value(statement, column)
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw lastError()
            }
        }
    }

    /// Runs `body` in a savepoint so calls can nest. Rolls back if `body` throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        savepointDepth += 1
        let name = "records_\(savepointDepth)"
        defer { savepointDepth -= 1 }
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE \(name)")
            return result
        } catch {
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }

    private func value(_ statement: OpaquePointer?, _ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}

/// Quotes an identifier for use in SQL.
func quoted(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
