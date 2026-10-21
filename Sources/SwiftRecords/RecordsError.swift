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
    /// A zone name is empty, starts with a dot, or contains a path separator.
    case invalidZoneName(String)
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
