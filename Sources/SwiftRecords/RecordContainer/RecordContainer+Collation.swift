import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension RecordContainer {
    /// The text collations each connection has, so SQLite sorts strings as Foundation does.
    enum Collation: String, CaseIterable {
        /// `String.localizedStandardCompare(_:)`, the default for a `String` `SortDescriptor`.
        case localizedStandard = "LOCALIZED_STANDARD"
        /// `String.localizedCompare(_:)`.
        case localized = "LOCALIZED"
    }

    /// Adds every ``Collation`` to `connection`. SQLite calls back into Swift to compare two
    /// strings, so `ORDER BY … COLLATE LOCALIZED_STANDARD` sorts exactly as a
    /// `SortDescriptor` with `.localizedStandard` does.
    static func registerCollations(on connection: OpaquePointer) {
        sqlite3_create_collation_v2(connection, Collation.localizedStandard.rawValue, SQLITE_UTF8, nil, { _, lhsCount, lhs, rhsCount, rhs in
            String(utf8: lhs, count: lhsCount).localizedStandardCompare(String(utf8: rhs, count: rhsCount)).sqlite
        }, nil)
        sqlite3_create_collation_v2(connection, Collation.localized.rawValue, SQLITE_UTF8, nil, { _, lhsCount, lhs, rhsCount, rhs in
            String(utf8: lhs, count: lhsCount).localizedCompare(String(utf8: rhs, count: rhsCount)).sqlite
        }, nil)
    }
}

private extension String {
    /// The text SQLite hands a collation, `count` bytes of UTF-8 that need not end in zero.
    init(utf8 bytes: UnsafeRawPointer?, count: Int32) {
        self = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(count)), as: UTF8.self)
    }
}

private extension ComparisonResult {
    /// The result as a collation returns it: negative, zero or positive.
    var sqlite: Int32 { Int32(rawValue) }
}
