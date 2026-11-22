/// A CloudKit zone, as this device sees it: its name and its owner.
///
/// ```swift
/// let notes: Zone = "Notes"        // your own private zone, the same as Zone("Notes")
/// let board = Zone.public          // the public database
/// ```
///
/// A zone that someone shared with you has the same name as on their device but
/// their user record name as its owner, so it is made when a share arrives, not by
/// the app. Which database a zone is in follows from its name and owner, so it is
/// never stored: see ``database``.
///
/// Your private default zone cannot report its changes, so it cannot sync, and its
/// name means the public database here.
public struct Zone: Hashable, Codable, Sendable {
    public var name: String
    /// The zone's owner, `"__defaultOwner__"` for your own zones.
    public var owner: String

    /// Your own private zone named `name`.
    public init(_ name: String) {
        self.init(name, owner: Self.defaultOwner)
    }

    /// The zone named `name` owned by `owner`, as a share arrives.
    init(_ name: String, owner: String) {
        self.name = name
        self.owner = owner
    }

    /// The public database's only zone, readable by every user of the app. It has no
    /// change tokens, so it is queried rather than synced, and it cannot hold
    /// `@Encrypted` values, shares or parents.
    public static let `public` = Zone("_defaultZone", owner: defaultOwner)

    /// The owner CloudKit gives your own zones, `CKCurrentUserDefaultName`.
    static let defaultOwner = "__defaultOwner__"
}

extension Zone {
    /// A CloudKit database.
    public enum Database: Hashable, Sendable {
        /// Your own data.
        case `private`
        /// Zones other people shared with you.
        case shared
        /// Data every user of the app can read.
        case `public`
    }

    /// The database the zone is in: public for the default zone, shared when someone
    /// else owns it, and private otherwise.
    public var database: Database {
        if name == Zone.public.name { return .public }
        return owner == Self.defaultOwner ? .private : .shared
    }
}

extension Zone: ExpressibleByStringLiteral {
    /// Your own private zone named by the literal.
    public init(stringLiteral name: String) {
        self.init(name)
    }
}
