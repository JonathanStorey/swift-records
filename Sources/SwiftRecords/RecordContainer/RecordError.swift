import Foundation

/// Why a record could not be saved.
///
/// Each case names the records and properties involved, so a log says what to fix and an
/// app can point at the record. Most cases are mistakes in the app's models or ids, which
/// the message explains. ``database(_:)`` is SQLite itself, such as a full disk.
///
/// ```swift
/// if let error = context.error(Note.self, id: note.id) {
///     print(error.localizedDescription)
/// }
/// ```
public enum RecordError: Error, Equatable {
    /// A record type the container was not given in `RecordContainer(for:)`.
    case notRegistered(type: String)
    /// A record name longer than CloudKit's 255 characters, from a long id.
    case nameTooLong(name: String)
    /// A reference to the record `reference` placed in another zone than its record's `zone`,
    /// which CloudKit cannot follow.
    case referenceOutsideZone(reference: String, zone: Zone)
    /// A relationship list, as in `"Note.tags"`, that does not name its inverse.
    case missingInverse(property: String)
    /// Two relationship lists that do not point at each other: `property` names `inverse`,
    /// but one of them is already paired with `pairedWith`.
    case mismatchedInverse(property: String, inverse: String, pairedWith: String)
    /// The record's own encoding threw, described by `description`.
    case unencodable(type: String, description: String)
    /// SQLite failed.
    case database(DatabaseError)
}

extension RecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRegistered(let type):
            "\(type) is not registered. Pass it to RecordContainer(for:)."
        case .nameTooLong(let name):
            "The record name \(name) is longer than CloudKit's 255 characters. Use a shorter id."
        case .referenceOutsideZone(let reference, let zone):
            "The reference to \(reference) points into another zone than \(zone.name). CloudKit follows a reference only within its record's zone."
        case .missingInverse(let property):
            "The relationship list \(property) does not name its inverse."
        case .mismatchedInverse(let property, let inverse, let pairedWith):
            "\(property) names \(inverse) as its inverse, but one of them is already paired with \(pairedWith). The two key paths must point at each other."
        case .unencodable(let type, let description):
            "\(type) could not be encoded: \(description)"
        case .database(let error):
            "The database failed: \(error.description)"
        }
    }
}

extension RecordError: CustomStringConvertible {
    public var description: String { errorDescription ?? "" }
}

extension RecordError {
    /// `error` as a record error for a record of type `type`: itself, a database error, or
    /// any other error as the record's own encoding failing.
    init(_ error: any Error, type: String) {
        switch error {
        case let error as RecordError: self = error
        case let error as DatabaseError: self = .database(error)
        default: self = .unencodable(type: type, description: "\(error)")
        }
    }
}
