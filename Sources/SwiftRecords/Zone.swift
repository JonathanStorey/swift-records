import Foundation

/// A named database file. The name is the file name without its extension, so the zone `"drafts"`
/// is stored as `drafts.sqlite`.
///
/// Zone files live in the app's Application Support directory under `Records/`. They never sync
/// through iCloud, but they are included in the device's own backups and in phone-to-phone transfers.
///
/// ```swift
/// extension Zone {
///     static let drafts: Zone = "drafts"
/// }
///
/// let store = try RecordStore(zone: .drafts)
/// ```
public struct Zone: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The file name without extension, or `nil` for an in-memory zone.
    public let name: String?

    public init(_ name: String) {
        self.name = name
    }

    public init(stringLiteral name: String) {
        self.init(name)
    }

    private init(inMemory: Void) {
        name = nil
    }

    /// The zone used when none is given: `default.sqlite`.
    public static let `default`: Zone = "default"

    /// A database that lives only as long as its store. Useful for tests and previews.
    public static let inMemory = Zone(inMemory: ())

    public var description: String { name ?? "in-memory" }

    /// The zone's file inside `directory`, or `nil` for an in-memory zone.
    public func url(in directory: URL) throws -> URL? {
        guard let name else { return nil }
        guard !name.isEmpty, !name.hasPrefix("."), name.rangeOfCharacter(from: Self.disallowed) == nil else {
            throw RecordStoreError.invalidZoneName(name)
        }
        return directory.appendingPathComponent(name + ".sqlite")
    }

    private static let disallowed = CharacterSet(charactersIn: "/\\:").union(.newlines).union(.controlCharacters)

    /// Where zone files are stored: `Application Support/Records`. On macOS the folder sits inside one
    /// named for the app's bundle identifier, because Application Support is shared by every app there.
    public static var defaultDirectory: URL {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        directory.appendPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        #endif
        directory.appendPathComponent("Records")
        return directory
    }

    /// Creates the directory if needed and makes sure it is included in device backups. The flag is
    /// cleared explicitly because earlier versions excluded the folder.
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var directory = directory
        try directory.setResourceValues(values)
        #endif
    }
}
