import Foundation
import Versioning

extension RecordContainer {
    /// Where a container keeps its database.
    ///
    /// ```swift
    /// try RecordContainer(for: Note.self)                                         // .local
    /// try RecordContainer(for: Note.self, storage: .inMemory)
    /// try RecordContainer(for: Note.self, storage: .local(in: "group.com.example.notes"))
    /// ```
    public struct Storage: Hashable, Sendable {
        /// The app group whose shared container holds the file, or `nil` for the app's own
        /// Application Support folder.
        let appGroup: String?
        /// Whether the database lives only in memory, with no file.
        let isInMemory: Bool

        /// In memory, so it starts empty and is gone when the container is released, as for
        /// previews and tests.
        public static let inMemory = Storage(appGroup: nil, isInMemory: true)

        /// In `default.records` in the app's Application Support folder, created if needed.
        public static let local = Storage(appGroup: nil, isInMemory: false)

        /// In `default.records` in the Application Support folder of `appGroup`'s shared
        /// container, so an app and its extensions share one database. App groups exist only
        /// on Apple platforms.
        public static func local(in appGroup: String) -> Storage {
            Storage(appGroup: appGroup, isInMemory: false)
        }
    }

    /// A container with each of `types` registered, kept in `storage`.
    ///
    /// ```swift
    /// let container = try RecordContainer(for: [Note.self, Tag.self])
    /// let preview = try RecordContainer(for: [Note.self], storage: .inMemory)
    /// ```
    public convenience init(for types: [any Codable.Type], storage: Storage = .local) throws(DatabaseError) {
        if storage.isInMemory {
            self.init()
            for type in types { register(type) }
        } else {
            try self.init(for: types, url: Self.storeURL(appGroup: storage.appGroup))
        }
    }

    /// A container stored in the file at `url`, created if it does not exist, with each of
    /// `types` registered, as tests reopen one across launches.
    convenience init(for types: [any Codable.Type], url: URL) throws(DatabaseError) {
        try self.init(url: url)
        for type in types { register(type) }
    }

    /// A container with each of the given types registered, kept in `storage`.
    ///
    /// ```swift
    /// let container = try RecordContainer(for: Note.self, Tag.self)
    /// ```
    ///
    /// The first type is separate, so at least one type is always given.
    public convenience init(for type: any Codable.Type, _ others: any Codable.Type..., storage: Storage = .local) throws(DatabaseError) {
        try self.init(for: [type] + others, storage: storage)
    }
}

extension RecordContainer {
    /// A record type the container can merge, decode and encode.
    typealias RecordType = any Codable.Type

    /// Registers `type`, so its records can merge on arrival by the type's own merge,
    /// ``DefaultMergeStrategy`` unless the type implements another.
    ///
    /// A plain struct needs no `Identifiable` conformance. Its id is chosen where it is
    /// saved, the way `List(_:id:)` takes any data.
    ///
    /// Its schema is stored too. When a type was registered before with a schema it can no
    /// longer read, as when a property was added that is not optional, it asserts once,
    /// since records saved under the older schema would be skipped. The new schema is
    /// stored first, so the next launch runs on.
    ///
    /// A new or changed schema also clears the sync engine's state, so the engine fetches
    /// everything again. Records that arrived while this app could not read them, or read
    /// them without a field it now has, come back whole. A version this device already has
    /// changes nothing, and unsent changes stay waiting in their rows.
    ///
    /// ```swift
    /// let container = RecordContainer(for: Note.self)
    /// ```
    private func register<Record: Codable>(_ type: Record.Type) {
        let name = Self.recordType(of: type)
        locked { registrations[name] = type }
        guard let schema = try? JSONSchema(for: type) else { return }
        let stored = storedSchema(named: name)
        guard stored != schema else { return }
        store(schema, named: name)
        engineStateData = nil
        if let stored {
            assert(schema.isSuperset(of: stored), "\(name) can no longer read records saved under its previous schema, so they would be skipped. Make each new property optional, and keep each property's type.")
        }
    }

    /// The registered Swift type for the record type named `type`.
    func registeredType(named type: String) throws -> RecordType {
        guard let registered = locked({ registrations[type] }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The record type \(type) is not registered."))
        }
        return registered
    }

    /// The record type a Swift type saves as, its name, as in `"Note"`.
    static func recordType(of type: Any.Type) -> String {
        String(describing: type)
    }

    /// The row's id and the record's name for the id `id` of a record of type `type`: a
    /// `UUID` id as it is, or, for any other id, the type and the id's text, a `String` id as
    /// it is and any other id as its JSON:
    ///
    /// - Text of only ASCII letters, digits, `-`, `_` and `.` follows one colon, as in
    ///   `"Page:intro"` or `"Invoice:42"`, so the name reads as the id.
    /// - Any other text is Base64URL-encoded without padding after two colons, as in
    ///   `"Page::Y2Fmw6k"` for `"café"`, which keeps the name to CloudKit's ASCII, with no
    ///   character that needs escaping in a URL.
    ///
    /// A ``Relationship``'s id is its name as it is, since it is already one.
    ///
    /// The same id always names the same record, so two devices that create it apart
    /// save one record. The type is part of the name because a record name is unique in
    /// its zone across every type. ``id(_:fromRecordName:)`` reads the id back.
    ///
    /// Throws an `EncodingError` when the name would be longer than CloudKit's 255
    /// characters, since a shortened name could not be read back as the id.
    static func recordName(for id: any Encodable, type: String) throws -> String {
        if let id = id as? UUID { return id.uuidString }
        let text = try (id as? String) ?? JSONRepresentation(id).description
        let name = if type == recordType(of: Relationship.self) {
            text   // already a record name, and one no other record can have
        } else if text.unicodeScalars.allSatisfy(Unicode.Scalar.isPlainRecordName) {
            type + ":" + text
        } else {
            type + "::" + Data(text.utf8).base64URLEncoded
        }
        guard name.utf8.count <= 255 else {
            throw EncodingError.invalidValue(id, .init(codingPath: [], debugDescription: "The record name \(name) is longer than CloudKit's 255 characters. Use a shorter id."))
        }
        return name
    }

    /// The id that ``recordName(for:type:)`` made `name` from, or `nil` when `name` is not
    /// one it made, or its id does not decode as `ID`.
    static func id<ID: Decodable>(_ type: ID.Type, fromRecordName name: String) -> ID? {
        // CloudKit names are case-sensitive, so only the uppercase name reads back as the UUID.
        if ID.self == UUID.self { return UUID(uuidString: name).flatMap { $0.uuidString == name ? $0 : nil } as? ID }
        guard let colon = name.firstIndex(of: ":") else { return nil }
        let rest = name[name.index(after: colon)...]
        let text: String
        if rest.first == ":" {
            guard let data = Data(base64URLEncoded: String(rest.dropFirst())) else { return nil }
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = String(rest)
        }
        if ID.self == String.self { return text as? ID }
        return try? JSONDecoder().decode(ID.self, from: Data(text.utf8))
    }
}

extension RecordContainer {
    /// `ours` merged with `theirs`, from `base` when there is one, by ``RecordMergeStrategy``, with
    /// any file the merge wrote, as a merged `@Asset`, copied into the row `id`'s folder.
    ///
    /// Every merge in the container runs here, and none throws a conflict:
    /// - The type's own merge runs first. Values it cannot settle keep the `side` given.
    /// - A version that cannot be read as `type` counts as missing: an unreadable `base`
    ///   makes a two-way merge, an unreadable `theirs` keeps `ours`, and an unreadable `ours`
    ///   takes `theirs`. Fields the type does not have are dropped.
    /// - A version that decodes as it is merges as it is, so an optional cleared on one side
    ///   stays cleared. Only when a key it lacks stops it decoding, as a version saved before
    ///   a field was added, is each missing key read from the other version, so the older
    ///   shape still decodes and leaves that field unchanged.
    func merged<Record: Codable>(_ ours: JSONRepresentation, with theirs: JSONRepresentation, from base: JSONRepresentation?, as type: Record.Type, id: RowID, favoring side: KeepMerge<JSONRepresentation>) throws -> JSONRepresentation {
        let mine = ours.decoded(as: Record.self, filling: theirs)
        let other = theirs.decoded(as: Record.self, filling: ours)
        let original = base?.decoded(as: Record.self, filling: ours.filling(from: theirs))
        let merged: Record
        switch (mine, other) {
        case let (mine?, other?):
            let strategy = RecordMergeStrategy<Record>(favoring: side)
            merged = if let original { try strategy.merge(base: original, ours: mine, theirs: other) } else { try strategy.merge(ours: mine, theirs: other) }
        case let (nil, other?): merged = other
        case (_?, nil): return ours
        case (nil, nil): return theirs
        }
        return storingAssets(of: merged, in: try JSONRepresentation(merged), id: id)
    }
}

private extension JSONRepresentation {
    /// This value decoded as `type`, or, when that fails, decoded with each top-level key it
    /// lacks taken from `other`, or `nil` when neither decodes.
    func decoded<T: Decodable>(as type: T.Type, filling other: JSONRepresentation) -> T? {
        if let value = try? decode(type) { return value }
        return try? filling(from: other).decode(type)
    }

    /// This object with each top-level key it lacks taken from `other`.
    func filling(from other: JSONRepresentation) -> JSONRepresentation {
        guard case .object(var pairs) = self, case .object(let others) = other else { return self }
        let keys = Set(pairs.map { $0.key })
        pairs += others.filter { !keys.contains($0.key) }
        return .object(pairs)
    }
}

private extension Unicode.Scalar {
    /// Whether a record name keeps this character as it is: an ASCII letter or digit, `-`,
    /// `_` or `.`.
    static func isPlainRecordName(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_", ".": true
        default: false
        }
    }
}

private extension Data {
    /// These bytes in Base64URL, `-` and `_` in place of `+` and `/`, with no `=` padding.
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The bytes of the Base64URL text `text`, with or without padding.
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
