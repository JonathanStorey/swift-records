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

    /// The database the zone lives in: `.private` for the person's own zones, `.shared` for zones other
    /// people shared with them. ≈ `CKDatabase.Scope`.
    public let scope: Scope

    /// Who owns a shared zone, as the server names users: a CloudKit user record name. `nil` for a private
    /// zone, which the signed-in person owns. ≈ `CKRecordZone.ID.ownerName`.
    public let owner: String?

    /// Which database a zone lives in. ≈ `CKDatabase.Scope` without the public database, which
    /// `CKSyncEngine` doesn't support.
    public enum Scope: String, Sendable, Hashable, Codable {
        /// The signed-in person's own data.
        case `private`
        /// Zones other people shared with them.
        case shared
    }

    /// The zone a context uses until you set another.
    public static let `default` = Zone(unchecked: "_default")

    /// A zone that lives only as long as its container and never touches disk, such as for scratch work or
    /// previews. It never syncs.
    public static let inMemory = Zone(unchecked: "_memory")

    /// A zone stored on this device that never syncs, such as for drafts or device settings. The container
    /// doesn't ask its sync provider about it.
    public static let localOnly = Zone(unchecked: "_local")

    /// The zone `@RecordStorage` keeps one setting in, `_settings.favorite` for the key `"favorite"`, so
    /// each setting syncs, resets and fails on its own. The key follows the rules for zone names.
    public static func settings(_ key: String) -> Zone {
        let key = key.lowercased()
        precondition(isValid(key), "\"\(key)\" is not a valid settings key. Use 1 to 64 letters, digits, - or _, starting with a letter.")
        return Zone(unchecked: settingsPrefix + key)
    }

    private static let settingsPrefix = "_settings."

    /// A table name made into a valid settings key, with anything a zone name can't hold turned into `_`.
    static func settingsKey(for table: String) -> String {
        let key = String(table.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return letters.contains(key.unicodeScalars.first ?? "_") ? key : "s" + key
    }

    /// The zone a stored name refers to, such as a file's or a server zone's, reserved names included.
    package init?(stored name: String) {
        if let zone = Zone.reserved.first(where: { $0.name == name }) {
            self = zone
        } else if name.hasPrefix(Zone.settingsPrefix), Zone.isValid(String(name.dropFirst(Zone.settingsPrefix.count))) {
            self.init(unchecked: name)
        } else if let zone = try? Zone(name) {
            self = zone
        } else {
            return nil
        }
    }

    /// The zone a stored name refers to in an owner's database, shared when `owner` is set.
    package init?(stored name: String, owner: String?) {
        guard let zone = Zone(stored: name) else { return nil }
        guard let owner else {
            self = zone
            return
        }
        guard !owner.isEmpty, owner.utf8.count <= 255 else { return nil }
        self.name = zone.name
        scope = .shared
        self.owner = owner
    }

    /// Throws `RecordsError.invalidZoneName` unless the name, once lowercased, is a valid zone name.
    public init(_ name: String) throws {
        let lowercased = name.lowercased()
        guard Self.isValid(lowercased) else { throw RecordsError.invalidZoneName(name) }
        self.name = lowercased
        scope = .private
        owner = nil
    }

    /// A zone someone else shared with the signed-in person. Its records are stored apart from the person's
    /// own, under `shared/<owner>/` in the container's folder, so a private zone of the same name never
    /// mixes with it. Throws `RecordsError.invalidZoneName` for an invalid name or an empty owner.
    public init(_ name: String, sharedBy owner: String) throws {
        let zone = try Zone(name)
        guard !owner.isEmpty, owner.utf8.count <= 255 else { throw RecordsError.invalidZoneName(name) }
        self.name = zone.name
        scope = .shared
        self.owner = owner
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
        scope = .private
        owner = nil
    }

    private enum CodingKeys: String, CodingKey {
        case name, owner
    }

    // A private zone is its name, as before sharing. A shared zone is its name and owner.
    public init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard let zone = Zone(stored: name) else { throw RecordsError.invalidZoneName(name) }
            self = zone
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        self = try Zone(name, sharedBy: try container.decode(String.self, forKey: .owner))
    }

    public func encode(to encoder: any Encoder) throws {
        if let owner {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(owner, forKey: .owner)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(name)
        }
    }

    /// The name for a private zone, and `shared/<owner>/<name>` for a shared one.
    public var description: String {
        owner.map { "shared/\($0)/\(name)" } ?? name
    }

    /// The zone's database file inside `directory`, or `nil` for `.inMemory`. A shared zone's file is in a
    /// folder for its owner.
    func url(in directory: URL) -> URL? {
        guard self != .inMemory else { return nil }
        guard let owner else { return directory.appendingPathComponent(name + ".sqlite") }
        return directory.appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent(Self.folderName(owner), isDirectory: true)
            .appendingPathComponent(name + ".sqlite")
    }

    /// An owner's name as a folder name: as it is when it is already lowercase letters, digits, `-` and
    /// `_`, and otherwise its UTF-8 in hex after an `x`, so names that differ only in case stay apart on a
    /// case-insensitive disk.
    static func folderName(_ owner: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        if owner.unicodeScalars.allSatisfy(safe.contains), owner.first != "x" {
            return owner
        }
        return "x" + owner.utf8.map { String(format: "%02x", $0) }.joined()
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
