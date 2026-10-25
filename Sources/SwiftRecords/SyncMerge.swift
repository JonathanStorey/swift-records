import Foundation

/// Settles a conflict between a record's unsent local edit and the server's copy.
enum SyncMerge {
    /// Merges two copies of a record's fields. With `base`, the values both last synced from, a property
    /// only one side changed keeps that change. Without it, any difference is a clash. A clash goes to the
    /// later edit, which is the server's copy unless `localIsLater`.
    static func merge(local: SyncFields, server: SyncFields, base: SyncFields?, localIsLater: Bool) -> SyncFields {
        var merged: SyncFields = [:]
        for key in Set(local.keys).union(server.keys) {
            merged[key] = mergeValue(local[key], server[key], base: base, key: key, preferLocal: localIsLater)
        }
        return merged
    }

    private static func mergeValue(_ local: SyncValue?, _ server: SyncValue?, base: SyncFields?, key: String, preferLocal: Bool) -> SyncValue? {
        if local == server { return local }
        if let base {
            if local == base[key] { return server }
            if server == base[key] { return local }
        }
        switch (local, server) {
        case (.ids(let localIDs)?, .ids(let serverIDs)?):
            var baseIDs: [UUID]?
            if let base {
                if case .ids(let ids)? = base[key] { baseIDs = ids } else { baseIDs = [] }
            }
            return .ids(mergeList(local: localIDs, server: serverIDs, base: baseIDs, preferLocal: preferLocal))
        default:
            return preferLocal ? local : server
        }
    }

    /// Merges an ordered relationship item by item. A removal on either side applies, an insertion keeps
    /// its place after the item it followed on its own side, and a reordering made on one side only wins.
    /// When both sides reordered, or there's no ancestor, the preferred side's order is kept.
    static func mergeList(local: [UUID], server: [UUID], base: [UUID]?, preferLocal: Bool) -> [UUID] {
        let preferred = preferLocal ? local : server
        let other = preferLocal ? server : local
        guard let base else {
            // Two-way: the union, in the preferred order, with the other side's extras after their predecessor.
            return inserting(other, into: preferred, keeping: { _ in true })
        }
        let baseSet = Set(base)
        let removed = baseSet.subtracting(local).union(baseSet.subtracting(server))
        let keep = { (id: UUID) in !removed.contains(id) }
        let baseOrder = base.filter(keep)
        let sharedOrder = { (list: [UUID]) in list.filter { baseSet.contains($0) && keep($0) } }
        let reorderedOnlyByOther = sharedOrder(preferred) == baseOrder && sharedOrder(other) != baseOrder
        let skeleton = reorderedOnlyByOther ? other : preferred
        let rest = reorderedOnlyByOther ? preferred : other
        return inserting(rest, into: skeleton.filter(keep), keeping: keep)
    }

    /// Adds the items of `list` missing from `result`, each after the item it follows in `list`.
    private static func inserting(_ list: [UUID], into result: [UUID], keeping keep: (UUID) -> Bool) -> [UUID] {
        var result = result
        var seen = Set(result)
        var anchor: Int?
        for id in list {
            if let index = result.firstIndex(of: id) {
                anchor = index
                continue
            }
            guard keep(id), seen.insert(id).inserted else { continue }
            let index = anchor.map { $0 + 1 } ?? 0
            result.insert(id, at: index)
            anchor = index
        }
        return result
    }
}
