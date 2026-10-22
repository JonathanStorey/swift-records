import Foundation

/// Zone names and the files they map to. A zone is a `String?` naming a database file inside a container's
/// folder: the zone `"drafts"` is stored as `drafts.sqlite`, and `nil`, the default zone, as `_default.sqlite`.
/// Names starting with an underscore are reserved for SwiftRecords.
enum ZoneFile {
    /// Throws unless the name is usable as a zone's file name.
    static func validate(_ zone: String?) throws {
        guard let zone else { return }
        guard !zone.isEmpty, !zone.hasPrefix("."), !zone.hasPrefix("_"), zone.rangeOfCharacter(from: disallowed) == nil else {
            throw RecordsError.invalidZoneName(zone)
        }
    }

    /// The zone's file inside `directory`.
    static func url(for zone: String?, in directory: URL) throws -> URL {
        try validate(zone)
        return directory.appendingPathComponent((zone ?? "_default") + ".sqlite")
    }

    private static let disallowed = CharacterSet(charactersIn: "/\\:").union(.newlines).union(.controlCharacters)
}

extension RecordContainer {
    /// The folder a container uses when given none: `Application Support/Records`. On macOS the folder sits inside one
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
    /// App Group entitlement. Pass it as the container's `directory`.
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
