import Foundation

extension RecordStore {
    /// Merges the files of assets both sides replaced, for each `@Asset` with a merge strategy. The
    /// strategy gets the bytes of the base, ours and theirs. When it returns one side's bytes that side's
    /// file is kept, and new bytes go to a new file the save copies in. An asset only one side changed, one
    /// side cleared, or whose bytes can't be read keeps the field-by-field result.
    func mergeAssets<R: Record>(
        _ type: R.Type, into result: inout SyncFields, local: SyncFields, server: SyncFields, base: SyncFields?
    ) {
        for field in R.cachedSchema.fields where field.isAsset {
            guard let strategy = field.assetMerge,
                  let ourName = Self.assetName(local[field.name]), let theirName = Self.assetName(server[field.name]),
                  ourName != theirName else { continue }
            let baseName = Self.assetName(base?[field.name])
            if base != nil, baseName == ourName || baseName == theirName { continue }
            guard let ours = assetData(named: ourName), let theirs = assetData(named: theirName),
                  let merged = strategy.merge(baseName.flatMap(assetData(named:)), ours, theirs) else { continue }
            if merged == ours {
                result[field.name] = local[field.name]
            } else if merged == theirs {
                result[field.name] = server[field.name]
            } else {
                let file = mergedAssetsDirectory.appendingPathComponent(Asset.makeName())
                do {
                    try FileManager.default.createDirectory(at: mergedAssetsDirectory, withIntermediateDirectories: true)
                    try merged.write(to: file, options: .atomic)
                    result[field.name] = .url(file)
                } catch {
                    continue
                }
            }
        }
    }

    /// An asset's bytes, from wherever its file is: stored, just received, kept as a merge base, or kept
    /// aside for undo.
    private func assetData(named name: String) -> Data? {
        let candidates = [
            assetURL(named: name), incomingAssetFiles[name],
            assetBasesDirectory.appendingPathComponent(name), releasedAssetsDirectory.appendingPathComponent(name),
        ]
        for case let file? in candidates {
            if let data = try? Data(contentsOf: file) { return data }
        }
        return nil
    }

    private static func assetName(_ value: SyncValue?) -> String? {
        guard case .url(let url)? = value else { return nil }
        return url.lastPathComponent
    }

    // MARK: Bases

    /// Files a three-way asset merge reads as the base: the server's copy of an asset the record here has
    /// since replaced. Each lives as long as a snapshot names it.
    var assetBasesDirectory: URL { assetsDirectory.appendingPathExtension("bases") }

    /// Keeps released files that a snapshot still names, as merge bases.
    func retainAssetBases(_ names: Set<String>) {
        guard syncEnabled, !names.isEmpty else { return }
        let named = names.intersection(snapshotAssetNames())
        guard !named.isEmpty else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: assetBasesDirectory, withIntermediateDirectories: true)
        for name in named {
            let kept = assetBasesDirectory.appendingPathComponent(name)
            guard !manager.fileExists(atPath: kept.path) else { continue }
            let file = assetURL(named: name)
            if (try? manager.linkItem(at: file, to: kept)) == nil {
                try? manager.copyItem(at: file, to: kept)
            }
        }
    }

    /// Keeps the server's files of assets a merge didn't take, since the server's copy is the next base.
    func retainAssetBases<R: Record>(of type: R.Type, server: SyncFields, merged: SyncFields) {
        let manager = FileManager.default
        for field in R.cachedSchema.fields where field.isAsset && field.assetMerge != nil {
            guard let name = Self.assetName(server[field.name]), Self.assetName(merged[field.name]) != name,
                  let file = incomingAssetFiles[name] else { continue }
            let kept = assetBasesDirectory.appendingPathComponent(name)
            guard !manager.fileExists(atPath: kept.path), !manager.fileExists(atPath: assetURL(named: name).path) else { continue }
            try? manager.createDirectory(at: assetBasesDirectory, withIntermediateDirectories: true)
            try? manager.copyItem(at: file, to: kept)
        }
    }

    /// Removes merge bases no snapshot names any more.
    func pruneAssetBases() {
        let manager = FileManager.default
        guard syncEnabled, let kept = try? manager.contentsOfDirectory(atPath: assetBasesDirectory.path), !kept.isEmpty else { return }
        let named = snapshotAssetNames()
        for name in kept where !named.contains(name) {
            try? manager.removeItem(at: assetBasesDirectory.appendingPathComponent(name))
        }
    }

    /// The asset names that snapshots hold, which are only kept for records with unsent edits.
    private func snapshotAssetNames() -> Set<String> {
        guard let rows = try? db.run("SELECT snapshot FROM \"_records_meta\" WHERE snapshot IS NOT NULL") else { return [] }
        var names: Set<String> = []
        for row in rows {
            for value in SyncFields.decoded(row["snapshot"])?.values.map({ $0 }) ?? [] {
                if let name = Self.assetName(value) { names.insert(name) }
            }
        }
        return names
    }
}
