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
/// let container = try RecordContainer(zone: .drafts)
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

    /// A database that lives only as long as its container. Useful for tests and previews.
    public static let inMemory = Zone(inMemory: ())

    public var description: String { name ?? "in-memory" }

    /// The zone's file inside `directory`, or `nil` for an in-memory zone.
    func url(in directory: URL) throws -> URL? {
        guard let name else { return nil }
        guard !name.isEmpty, !name.hasPrefix("."), name.rangeOfCharacter(from: Self.disallowed) == nil else {
            throw RecordsError.invalidZoneName(name)
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

    #if canImport(Darwin)
    /// The folder for zone files shared with an app extension, such as a widget: `Library/Application
    /// Support/Records` inside the App Group's container. Returns `nil` when the app doesn't have the
    /// App Group entitlement. Pass it as the `directory` when opening each container.
    public static func directory(appGroup identifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent("Library/Application Support/Records", isDirectory: true)
    }
    #endif

    /// Creates the directory if needed and makes sure it is included in device backups. The flag is
    /// cleared explicitly because earlier versions excluded the folder.
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        // `isExcludedFromBackup` is stored as this attribute. Removing it directly avoids
        // `setResourceValues`, which can skip the write when a cached value already reads false.
        if removexattr(directory.path, "com.apple.metadata:com_apple_backup_excludeItem", 0) != 0, errno != ENOATTR {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: directory])
        }
        #endif
    }
}
