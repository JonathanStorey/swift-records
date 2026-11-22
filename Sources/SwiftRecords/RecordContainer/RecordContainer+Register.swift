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
    public convenience init(for types: [any (Codable & Mergeable).Type], storage: Storage = .local) throws(DatabaseError) {
        if storage.isInMemory {
            self.init()
            for type in types { register(type) }
        } else {
            try self.init(for: types, url: Self.storeURL(appGroup: storage.appGroup))
        }
    }

    /// A container stored in the file at `url`, created if it does not exist, with each of
    /// `types` registered, as tests reopen one across launches.
    convenience init(for types: [any (Codable & Mergeable).Type], url: URL) throws(DatabaseError) {
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
    public convenience init(for type: any (Codable & Mergeable).Type, _ others: any (Codable & Mergeable).Type..., storage: Storage = .local) throws(DatabaseError) {
        try self.init(for: [type] + others, storage: storage)
    }
}

extension RecordContainer {
    /// A record type the container can merge, decode and encode.
    typealias RecordType = any (Codable & Mergeable).Type

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
    private func register<Record: Codable & Mergeable>(_ type: Record.Type) {
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
    /// `UUID` id itself, or, for any other id, a stable hash of the record type and the
    /// id's JSON, as in `"Page|\"intro\""`.
    ///
    /// The same id always names the same record, so two devices that create it apart
    /// save one record. The type is part of the hash because a record name is unique in
    /// its zone across every type. A `UUID` id is kept as it is so a reference to the
    /// record can be read back as the id.
    static func recordID(for id: any Encodable, type: String) throws -> UUID {
        if let id = id as? UUID { return id }
        return UUID(stableHashOf: type + "|" + (try JSONRepresentation(id)).description)
    }
}

extension RecordContainer {
    /// `ours` merged with `theirs`, from `base` when there is one, by `type`'s own merge,
    /// with any file the merge wrote, as a merged `@Asset`, copied into the row `id`'s folder.
    ///
    /// The merge settles itself, so the user never sees it:
    /// - Values that still conflict after the type's merge are settled by ``favoring``.
    /// - A version that cannot be read as `type` counts as missing: an unreadable `base`
    ///   makes a two-way merge, an unreadable `theirs` keeps `ours`, and an unreadable `ours`
    ///   takes `theirs`. Fields the type does not have are dropped.
    /// - A version that decodes as it is merges as it is, so an optional cleared on one side
    ///   stays cleared. Only when a key it lacks stops it decoding, as a version saved before
    ///   a field was added, is each missing key read from the other version, so the older
    ///   shape still decodes and leaves that field unchanged.
    func merged<Record: Codable & Mergeable>(_ ours: JSONRepresentation, with theirs: JSONRepresentation, from base: JSONRepresentation?, as type: Record.Type, id: UUID) throws -> JSONRepresentation {
        let mine = ours.decoded(as: Record.self, filling: theirs)
        let other = theirs.decoded(as: Record.self, filling: ours)
        let original = base?.decoded(as: Record.self, filling: ours.filling(from: theirs))
        let merged: Record
        switch (mine, other) {
        case let (mine?, other?): merged = try settled(mine, with: other, from: original)
        case let (nil, other?): merged = other
        case (_?, nil): return ours
        case (nil, nil): return theirs
        }
        return storingAssets(of: merged, in: try JSONRepresentation(merged), id: id)
    }
}

private extension RecordContainer {
    /// `ours` merged with `theirs` by the type's own merge, and, where that conflicts, again
    /// with ``DefaultMergeStrategy`` keeping the ``favoring`` side at each conflicting value,
    /// which still merges each `Mergeable` property by its own merge.
    func settled<Record: Codable & Mergeable>(_ ours: Record, with theirs: Record, from base: Record?) throws(MergeConflict) -> Record {
        do {
            if let base { return try ours.merging(with: theirs, from: base) }
            return try ours.merging(with: theirs)
        } catch {
            let side: KeepMerge<Record> = switch favoring {
            case .ours: .ours
            case .theirs: .theirs
            }
            let strategy = DefaultMergeStrategy<Record>(favoring: side)
            if let base { return try ours.merging(with: theirs, from: base, using: strategy) }
            return try ours.merging(with: theirs, using: strategy)
        }
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
