import Foundation
import Versioning

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
    /// ```swift
    /// let container = RecordContainer()
    /// container.register(Note.self)
    /// ```
    func register<Record: Codable & Mergeable>(_ type: Record.Type) {
        let name = Self.recordType(of: type)
        locked { registrations[name] = type }
        guard let schema = try? JSONSchema(for: type) else { return }
        let stored = storedSchema(named: name)
        guard stored != schema else { return }
        store(schema, named: name)
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
