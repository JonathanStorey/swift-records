import Foundation

/// Every error SwiftRecords throws, whether a save failed on this device or a sync server refused a record.
/// A context's `status` shows the same error as `.failed(_:)`.
public enum RecordsError: Error, Hashable, Sendable {
    /// SQLite failed, for example because the disk is full or the file is damaged.
    case database(code: Int32, message: String)
    /// A property's value can't be stored, such as a `Double` that is NaN.
    case invalidValue(type: String, property: String)
    /// Records refer to each other through forward properties. Use `@Reference(from:)` for back-pointers.
    case cycle(type: String)
    /// An inverse key path does not name a property of a `@Record` type.
    case unknownInverse(String)
    /// A zone name, once lowercased, isn't 1 to 64 letters, digits, `-` or `_` starting with a letter.
    case invalidZoneName(String)
    /// A zone that never syncs, `.inMemory` or `.localOnly`, was given where a sync server's zone is needed.
    case unsyncedZone(Zone)
    /// Archived CloudKit system fields don't belong to the record they were given with: they don't unarchive,
    /// or they name another record, type or zone.
    case mismatchedSystemFields(type: String, id: UUID)
    /// A registered record type is set up in a way that would lose or mix up data, such as two types
    /// stored under one name. `reason` says what to fix.
    case invalidSchema(type: String, reason: String)
    /// The sync account is out of storage. Changes stay on this device until there is room.
    case storageFull
    /// The sync server refused a record for good.
    case rejected(type: String, id: UUID)
    /// A stored or received record doesn't decode as this version of the app's type. A received one is kept
    /// and tried again after the app updates.
    case incompatibleRecord(type: String, id: UUID)
}

extension RecordsError {
    /// Maps SQLite failures into `RecordsError` and leaves every other error as it is, such as one thrown by
    /// the caller's own transaction body.
    static func mapping(_ error: any Error) -> any Error {
        if let error = error as? SQLiteError {
            return RecordsError.database(code: error.code, message: error.message)
        }
        return error
    }
}
