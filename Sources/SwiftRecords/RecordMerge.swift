import Foundation
@_exported import Merging

extension RecordStore {
    /// Merges a record's local fields with another copy's, against `base`, the copy both started from.
    ///
    /// Fields both sides changed merge as the record's own type: node by node, with `@Merged` strategies
    /// and a `Mergeable` type's own merge, and a value both sides changed differently goes to the later
    /// edit, `local` when `localIsLater`. Timestamps, pointers, assets and fields this version of the app
    /// doesn't know merge field by field, as does a record whose fields don't decode.
    func mergeFields<R: Record>(
        _ type: R.Type, local: SyncFields, server: SyncFields, base: SyncFields?, localIsLater: Bool
    ) -> SyncFields {
        let byField = SyncMerge.merge(local: local, server: server, base: base, localIsLater: localIsLater)
        let fields = R.cachedSchema.fields.filter {
            $0.name != "id" && $0.isStored && $0.timestamp == nil && !$0.isPointer && !$0.isAsset
        }
        // A field only one side changed merges the same either way.
        let bothChanged = fields.contains { field in
            guard let base else { return local[field.name] != server[field.name] }
            return local[field.name] != base[field.name] && server[field.name] != base[field.name]
        }
        guard bothChanged else { return byField }
        do {
            let ours = try record(R.self, from: local)
            let theirs = try record(R.self, from: server)
            let original = try base.map { try record(R.self, from: $0) }
            let merged = try syncFields(of: Self.merge(ours, theirs, base: original, favoringOurs: localIsLater))
            var result = byField
            for field in fields {
                result[field.name] = merged[field.name]
            }
            return result
        } catch {
            return byField
        }
    }

    /// Brings an unsaved edit up to date with the stored record when a save or a sync elsewhere changed it
    /// after the edit started from `base`. A field only the store changed takes the stored value, and one
    /// both changed merges favoring the edit, as the save would. The returned base is what's stored now,
    /// so the save merges only what changes after this, and `@Merged(.sum)` doesn't count a change twice.
    /// Pointers, assets and timestamps keep the old base and merge at save, as before. `clashes` names the
    /// fields where the edit's value won over the stored one. Returns `nil` when nothing changed since
    /// `base` or the record is no longer stored.
    func rebase<R: Record>(_ edit: R, base: SyncFields) throws -> (edit: R, base: SyncFields, clashes: Set<String>)? {
        guard let stored = try storedFields(R.self, id: edit.id), stored != base else { return nil }
        let fields = R.cachedSchema.fields.filter {
            $0.name != "id" && $0.isStored && $0.timestamp == nil && !$0.isPointer && !$0.isAsset
        }
        let ours = try syncFields(of: edit)
        var local = base
        var newBase = base
        for field in fields {
            local[field.name] = ours[field.name]
            newBase[field.name] = stored[field.name]
        }
        let merged = mergeFields(R.self, local: local, server: stored, base: base, localIsLater: true)
        // A field clashed when the merge had to pick a side: favoring the stored copy instead ends
        // differently. A strategy such as `.sum` that combines both sides ends the same either way.
        let bothChanged = fields.filter {
            local[$0.name] != base[$0.name] && stored[$0.name] != base[$0.name] && local[$0.name] != stored[$0.name]
        }
        var clashes: Set<String> = []
        if !bothChanged.isEmpty {
            let theirs = mergeFields(R.self, local: local, server: stored, base: base, localIsLater: false)
            clashes = Set(bothChanged.filter { merged[$0.name] != theirs[$0.name] }.map(\.name))
        }
        let changed = fields.filter { merged[$0.name] != ours[$0.name] }
        guard !changed.isEmpty else { return (edit, newBase, clashes) }
        let source = try record(R.self, from: merged)
        var rebased = edit
        for field in changed {
            guard Self.copy(field.keyPath, from: source, into: &rebased) else { return nil }
        }
        return (rebased, newBase, clashes)
    }

    /// Copies one property's value, or returns `false` when the property can't be set.
    static func copy<R>(_ keyPath: PartialKeyPath<R>, from source: R, into target: inout R) -> Bool {
        func set<Value>(_ value: Value) -> Bool {
            guard let writable = keyPath as? WritableKeyPath<R, Value> else { return false }
            target[keyPath: writable] = value
            return true
        }
        return _openExistential(source[keyPath: keyPath], do: set)
    }

    /// Merges with the type's own merge when it's `Mergeable`, and otherwise, or when that throws, node by
    /// node with every clash going to the favored side.
    private static func merge<R: Record>(_ ours: R, _ theirs: R, base: R?, favoringOurs: Bool) -> R {
        if let mergeable = ours as? any Mergeable, let merged = try? mergeOwn(mergeable, theirs, base: base) as? R {
            return merged
        }
        if favoringOurs {
            let strategy = CodableTotalMerge<R, OursSide>()
            return base.map { strategy.merge(base: $0, ours: ours, theirs: theirs) } ?? strategy.merge(ours: ours, theirs: theirs)
        }
        let strategy = CodableTotalMerge<R, TheirsSide>()
        return base.map { strategy.merge(base: $0, ours: ours, theirs: theirs) } ?? strategy.merge(ours: ours, theirs: theirs)
    }

    private static func mergeOwn<M: Mergeable>(_ ours: M, _ theirs: Any, base: Any?) throws -> M {
        guard let theirs = theirs as? M else { throw CocoaError(.coderValueNotFound) }
        guard let base else { return try ours.merging(with: theirs) }
        guard let base = base as? M else { throw CocoaError(.coderValueNotFound) }
        return try ours.merging(with: theirs, from: base)
    }

    private static let mergeID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// A record decoded from sync fields alone. Its relationships are empty, since children and links
    /// merge as records of their own.
    private func record<R: Record>(_ type: R.Type, from fields: SyncFields) throws -> R {
        // Every version gets the same ID, so the IDs never differ in a merge.
        var row: [String: SQLiteValue] = ["id": try ValueCoding.encode(Self.mergeID)]
        for field in R.cachedSchema.fields where field.name != "id" && field.isStored && field.timestamp != .synced {
            let value = fields[field.name] ?? field.previousNames.lazy.compactMap { fields[$0] }.first
            if field.isAsset {
                if case .url(let url)? = value { row[field.name] = .text(url.lastPathComponent) }
            } else if let value {
                row[field.name] = try Self.column(value, as: Swift.type(of: field.keyPath).valueType)
            }
        }
        return try R(from: RecordDecoder<R>(row: row, loader: FieldsOnly(store: self)))
    }

    /// A record's plain fields as sync fields, the way they're read from its row.
    private func syncFields<R: Record>(of record: R) throws -> SyncFields {
        let columns = Dictionary(try RecordEncoder.encode(record).columns, uniquingKeysWith: { _, last in last })
        var fields: SyncFields = [:]
        for field in R.cachedSchema.fields where field.name != "id" && field.isStored && field.timestamp == nil {
            guard !field.isPointer, !field.isAsset, let value = columns[field.name], value != .null else { continue }
            fields[field.name] = try Self.syncValue(of: value, as: Swift.type(of: field.keyPath).valueType)
        }
        return fields
    }
}

/// Loads nothing, so a record decodes from its fields alone.
private struct FieldsOnly: RelationLoader {
    let store: RecordStore

    func loadRelated<R: Record>(_ type: R.Type, ownerID: SQLiteValue, field: RecordSchema<R>.Field) throws -> [any Record] { [] }
    func hasRelated<R: Record>(_ type: R.Type, ownerID: SQLiteValue, field: RecordSchema<R>.Field) throws -> Bool { false }
    func loadInverse(targetID: SQLiteValue, inverse: AnyKeyPath) throws -> [SQLiteValue] { [] }
    func assetURL(named name: String) -> URL { store.assetURL(named: name) }
    func syncedDate(table: String, id: SQLiteValue) throws -> Date? { nil }
}
