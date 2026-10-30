import Foundation

/// Merges a record's fields one by one, the fallback for what `mergeFields` can't merge as the record's
/// type.
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
        return preferLocal ? local : server
    }
}
