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

    /// Merges an ordered relationship item by item. A removal on either side applies, and an insertion keeps
    /// its place after the item it followed on its own side. A move is an item that left its order relative
    /// to the others, found as the items outside the longest run each side kept in the ancestor's order, so
    /// moves made on both sides all apply. An item both sides moved takes the preferred side's place, as does
    /// the whole order when there's no ancestor.
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
        let shared = { (list: [UUID]) in list.filter { baseSet.contains($0) && keep($0) } }
        let preferredMoves = moves(from: baseOrder, to: shared(preferred))
        let otherMoves = moves(from: baseOrder, to: shared(other)).subtracting(preferredMoves)
        var result = baseOrder.filter { !preferredMoves.contains($0) && !otherMoves.contains($0) }
        place(otherMoves, from: shared(other), into: &result, skipping: preferredMoves)
        place(preferredMoves, from: shared(preferred), into: &result, skipping: otherMoves)
        result = inserting(preferred, into: result, keeping: keep)
        return inserting(other, into: result, keeping: keep)
    }

    /// The items of `list` that left the order of `base`: those outside a longest common subsequence.
    private static func moves(from base: [UUID], to list: [UUID]) -> Set<UUID> {
        guard list != base else { return [] }
        let n = base.count, m = list.count
        // lengths[i][j] is the longest common subsequence of base[i...] and list[j...].
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = base[i] == list[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var stayed: Set<UUID> = []
        var i = 0, j = 0
        while i < n, j < m {
            if base[i] == list[j] {
                stayed.insert(base[i])
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return Set(list).subtracting(stayed)
    }

    /// Puts each moved item after the item it follows in `list`, skipping items the other side moved, whose
    /// place is that side's to decide. An item with nothing before it goes first.
    private static func place(_ moved: Set<UUID>, from list: [UUID], into result: inout [UUID], skipping: Set<UUID>) {
        guard !moved.isEmpty else { return }
        var anchor: UUID?
        for id in list {
            if moved.contains(id) {
                let index = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                result.insert(id, at: index)
                anchor = id
            } else if !skipping.contains(id) {
                anchor = id
            }
        }
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
