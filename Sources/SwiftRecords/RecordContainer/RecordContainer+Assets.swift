import Foundation
import Versioning

extension RecordContainer {
    /// The folder holding the asset files of the row `id`, one file for each version that
    /// uses it, so `base`, `ours` and `theirs` can each keep their own file for a merge.
    ///
    /// Each zone has its own folder, named by a hash of its owner and name, which may hold
    /// any character, so a copy of a record in another zone keeps its own files.
    func assetFolder(id: RowID) -> URL {
        assets
            .appendingPathComponent(UUID(stableHashOf: id.zone.owner + "|" + id.zone.name).uuidString, isDirectory: true)
            .appendingPathComponent(id.name.uuidString, isDirectory: true)
    }

    /// `json` with the file at each of `files`, by field, copied into the row's folder under
    /// a new name, and the field pointing at the copy.
    ///
    /// A file already in the folder is kept as it is. A file with the same bytes as one the
    /// field already has in the folder points at that one instead, so saving the same bytes
    /// again is no change and uploads nothing. A file that cannot be copied keeps its URL.
    /// On APFS the copy is a clone, which shares the original's blocks.
    func storingAssets(_ files: [String: URL], in json: JSONRepresentation, id: RowID) -> JSONRepresentation {
        let folder = assetFolder(id: id)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var stored: [String: JSONRepresentation] = [:]
        for (key, file) in files where !file.absoluteString.hasPrefix(folder.absoluteString) {
            let same = existing.first { name in
                name.hasPrefix("\(key)-") && FileManager.default.contentsEqual(atPath: folder.appendingPathComponent(name).path, andPath: file.path)
            }
            if let same {
                stored[key] = .string(folder.appendingPathComponent(same).absoluteString)
                continue
            }
            // Named for its field, so a folder reads at a glance, and unique, so no version's
            // file is ever replaced.
            let copy = folder.appendingPathComponent("\(key)-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: copy)
                stored[key] = .string(copy.absoluteString)
            } catch {
                continue
            }
        }
        return stored.isEmpty ? json : json.replacing(stored)
    }

    /// `json`, the encoding of `record`, with the file of each `Asset` property of `record`
    /// copied into the row's folder, as ``storingAssets(_:in:id:)`` does.
    func storingAssets(of record: Any, in json: JSONRepresentation, id: RowID) -> JSONRepresentation {
        storingAssets(json.assetFiles(of: record), in: json, id: id)
    }

    /// `json` with each top-level file in the row's folder named relative to the folder, as
    /// the table stores it, so the database still finds its files when the app's container
    /// moves, as it can on iOS when the app updates.
    func portable(_ json: JSONRepresentation, id: RowID) -> JSONRepresentation {
        let folder = assetFolder(id: id).absoluteString
        return json.mappingTopLevelStrings { $0.hasPrefix(folder) ? Self.assetScheme + $0.dropFirst(folder.count) : nil }
    }

    /// `json`, as the table stores it, with each file named by ``portable(_:id:)`` pointing
    /// into the row's folder again.
    func resolved(_ json: JSONRepresentation, id: RowID) -> JSONRepresentation {
        let folder = assetFolder(id: id)
        return json.mappingTopLevelStrings { text in
            text.hasPrefix(Self.assetScheme) ? folder.appendingPathComponent(String(text.dropFirst(Self.assetScheme.count))).absoluteString : nil
        }
    }

    /// The prefix of a file name relative to its row's folder, as the table stores it.
    private static let assetScheme = "versioning-asset:"
}

private extension JSONRepresentation {
    /// The file of each `Asset` property of `record`, by the key this value, its encoding,
    /// holds it under, so a custom `CodingKeys` is followed. Only a top-level property, since
    /// a nested value is stored as JSON, where a record cannot hold an asset.
    func assetFiles(of record: Any) -> [String: URL] {
        let files = Mirror(reflecting: record).properties.compactMap { ($0.value as? any AnyAsset)?.projectedValue }
        guard !files.isEmpty, case .object(let pairs) = self else { return [:] }
        var found: [String: URL] = [:]
        for pair in pairs {
            guard case .string(let text) = pair.value, let file = files.first(where: { $0.absoluteString == text }) else { continue }
            found[pair.key] = file
        }
        return found
    }

    /// This object with the value at each key of `values` replaced.
    func replacing(_ values: [String: JSONRepresentation]) -> JSONRepresentation {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.map { (key: $0.key, value: values[$0.key] ?? $0.value) })
    }

    /// This object with each top-level string that `transform` returns a value for replaced by it.
    func mappingTopLevelStrings(_ transform: (String) -> String?) -> JSONRepresentation {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.map { pair in
            guard case .string(let text) = pair.value, let mapped = transform(text) else { return pair }
            return (key: pair.key, value: .string(mapped))
        })
    }
}
