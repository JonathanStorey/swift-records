import Foundation

// MARK: - Undo

extension RecordStore {
    /// Each record a journaled transaction changed, as it was before the first change, so the transaction
    /// can be undone by putting them back. Cascades, links and references are records like any other.
    struct Journal: Sendable {
        enum Image: Sendable {
            /// The record didn't exist.
            case absent
            case stored(SyncFields)
        }

        private(set) var images: [RowKey: Image] = [:]
        /// The records in the order they were first changed.
        private(set) var order: [RowKey] = []

        var isEmpty: Bool { order.isEmpty }

        mutating func add(_ key: RowKey, _ image: @autoclosure () throws -> Image) rethrows {
            guard images[key] == nil else { return }
            images[key] = try image()
            order.append(key)
        }
    }

    /// Runs `body` while journaling, and returns what it changed. Nested calls join the outer journal.
    func journaling<T>(_ body: () throws -> T) throws -> (result: T, journal: Journal) {
        try locked {
            guard journal == nil else { return (try body(), Journal()) }
            journal = Journal()
            defer { journal = nil }
            let result = try body()
            return (result, journal!)
        }
    }

    /// Puts back every record the journal holds, deleting the ones that didn't exist. Run it inside
    /// `journaling` to get the journal that undoes it in turn.
    func restore(_ journal: Journal) throws {
        try transaction {
            // Deletes go first, so a cascade can't remove a record restored after it.
            for key in journal.order {
                if case .absent? = journal.images[key] {
                    try deleteRow(key.table, id: key.id)
                }
            }
            for key in journal.order {
                guard case .stored(let fields)? = journal.images[key] else { continue }
                try applySyncFields(
                    table: key.table, id: try ValueCoding.decode(UUID.self, from: key.id), fields: fields.mapValues(releasedAsset)
                )
            }
        }
    }

    /// Before a record changes, keeps its values for undo and its synced values for a merge.
    func beforeChange(_ table: String, id: SQLiteValue) throws {
        try journalBeforeChange(table, id: id)
        try snapshotBeforeChange(table, id: id)
    }

    /// Keeps a record's values before the journaled transaction first changes it. A type that isn't
    /// registered can't be read back, so it's left out rather than restored as missing.
    func journalBeforeChange(_ table: String, id: SQLiteValue) throws {
        guard journal != nil, registered[table] != nil else { return }
        try journal!.add(RowKey(table: table, id: id), try syncFields(table: table, id: id).map { .stored($0) } ?? .absent)
    }

    /// Registers a type before a journaled change, so its records can be read back for undo.
    func registerForJournal<R: Record>(_ type: R.Type) throws {
        guard journal != nil, registered[R.table] == nil else { return }
        try register([R.self])
    }

    /// Removes an asset file no record holds, or keeps it aside while journaling so undo can bring it back.
    func keepOrRemoveReleasedFile(named name: String) {
        let file = assetURL(named: name)
        guard journal != nil else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let kept = releasedAssetsDirectory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: releasedAssetsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: kept)
        if (try? FileManager.default.moveItem(at: file, to: kept)) == nil {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Points an asset whose file was released at the copy kept aside.
    private func releasedAsset(_ value: SyncValue) -> SyncValue {
        guard case .url(let url) = value, !FileManager.default.fileExists(atPath: url.path) else { return value }
        let kept = releasedAssetsDirectory.appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: kept.path) ? .url(kept) : value
    }
}
