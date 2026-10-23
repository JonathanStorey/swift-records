import Foundation

/// A zone: a database file inside a container's folder, and the matching zone on a sync server. The zone
/// `"drafts"` is stored as `drafts.sqlite`, and `.default` as `_default.sqlite`.
///
/// A name is lowercased, then must be 1 to 64 characters of `a`–`z`, `0`–`9`, `-` and `_`, starting with a
/// letter. That keeps it a safe folder and file name everywhere, and stops `"Drafts"` and `"drafts"` from
/// sharing one file on a case-insensitive disk. Names starting with an underscore are reserved for SwiftRecords.
///
/// ```swift
/// context.zone = "drafts"                 // a literal: an invalid one stops the app
/// let zone = try Zone(userTypedName)      // anything else: throws `RecordsError.invalidZoneName`
/// ```
public struct Zone: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The zone's lowercased name, which is also its file's name.
    public let name: String

    /// The zone a context uses until you set another.
    public static let `default` = Zone(unchecked: "_default")

    /// A zone that lives only as long as its container and never touches disk, such as for scratch work or
    /// previews. It never syncs.
    public static let inMemory = Zone(unchecked: "_memory")

    /// A zone stored on this device that never syncs, such as for drafts or device settings. The container
    /// doesn't ask its sync provider about it.
    public static let localOnly = Zone(unchecked: "_local")

    /// Throws `RecordsError.invalidZoneName` unless the name, once lowercased, is a valid zone name.
    public init(_ name: String) throws {
        let lowercased = name.lowercased()
        guard Self.isValid(lowercased) else { throw RecordsError.invalidZoneName(name) }
        self.name = lowercased
    }

    /// A zone named in code. An invalid name is a programming error, so it stops the app.
    public init(stringLiteral name: String) {
        guard let zone = try? Zone(name) else {
            preconditionFailure("\"\(name)\" is not a valid zone name. Use 1 to 64 letters, digits, - or _, starting with a letter.")
        }
        self = zone
    }

    private init(unchecked name: String) {
        self.name = name
    }

    public init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = try Zone.reserved.first { $0.name == name } ?? Zone(name)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }

    public var description: String { name }

    /// The zone's database file inside `directory`, or `nil` for `.inMemory`.
    func url(in directory: URL) -> URL? {
        self == .inMemory ? nil : directory.appendingPathComponent(name + ".sqlite")
    }

    /// Whether the container asks its sync provider about this zone.
    var canSync: Bool { self != .inMemory && self != .localOnly }

    private static let reserved: [Zone] = [.default, .inMemory, .localOnly]

    private static func isValid(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first, letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
    private static let allowed = letters.union(CharacterSet(charactersIn: "0123456789-_"))
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
