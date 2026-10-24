import Foundation

/// Syncs through a folder of files, such as the app's iCloud container, which the system then copies
/// between the person's devices. No server code is needed.
///
/// ```swift
/// let container = try RecordContainer(for: [Recipe.self], syncProvider: { _ in FileSyncProvider() })
/// ```
///
/// Each record is one readable JSON file, at `Records/<zone>/<type>/<id>.json`, and each asset is a plain
/// file in `Records/<zone>/_assets/`. A deletion stays behind as a small file so other devices hear of it.
/// Downloads remember every file they have seen rather than a time, so devices whose clocks disagree
/// can't miss each other's changes. Deleting a zone's folder counts as a server reset.
///
/// Other devices' changes arrive without a refresh. In iCloud an `NSMetadataQuery` watches the folder,
/// and anywhere else the folder is checked every `watchInterval`. When iCloud keeps two versions of a
/// record file because devices wrote it at once, `NSFileVersion` settles them: the copy with the later
/// `modified` date stays, as a whole record.
///
/// iCloud needs the iCloud capability with iCloud Documents turned on. While the person is signed out of
/// iCloud, the container reports `signedOut`.
public final class FileSyncProvider: SyncProvider, @unchecked Sendable {
    /// Where the files live.
    public enum Location: Sendable, Hashable {
        /// The app's iCloud container, hidden from the Files app.
        case iCloud
        /// The `Documents` folder of the app's iCloud container, which people can see in the Files app and
        /// iCloud Drive. Showing it there takes `NSUbiquitousContainers` in the app's Info.plist.
        case iCloudDrive
        /// An App Group's shared folder, so an app and its extensions sync on one device.
        case appGroup(String)
        /// The app's Application Support folder on this device, handy for tests and the simulator.
        case applicationSupport
        /// Any folder, such as a network drive.
        case other(directory: URL)
    }

    public let location: Location
    private let lock = NSLock()
    /// How often a folder outside iCloud is checked for other devices' changes, or `nil` to check only
    /// on refresh. iCloud folders are watched as they change.
    public let watchInterval: Duration?
    private var resolved: URL??
    private var pushes: [UUID: AsyncStream<[Zone]>.Continuation] = [:]
    private var watching = false
    private var poller: Task<Void, Never>?
    /// Change marks this provider wrote, which its own watcher ignores.
    private var ownMarks: Set<String> = []
    #if canImport(Darwin)
    private var query: MetadataWatcher?
    #endif

    public init(location: Location = .iCloud, watchInterval: Duration? = .seconds(10)) {
        self.location = location
        self.watchInterval = watchInterval
    }

    deinit {
        poller?.cancel()
        #if canImport(Darwin)
        query?.stop()
        #endif
    }

    /// The folder the zones live in, or `nil` while it isn't available, as when signed out of iCloud.
    public var directory: URL? {
        lock.withLock {
            if let resolved { return resolved }
            let url = Self.resolve(location)?.appendingPathComponent("Records", isDirectory: true)
            // An iCloud folder can appear later, once the person signs in.
            if url != nil || !location.isICloud {
                resolved = .some(url)
            }
            return url
        }
    }

    private static func resolve(_ location: Location) -> URL? {
        let manager = FileManager.default
        switch location {
        case .iCloud:
            #if canImport(Darwin)
            return manager.url(forUbiquityContainerIdentifier: nil)
            #else
            return nil
            #endif
        case .iCloudDrive:
            #if canImport(Darwin)
            return manager.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true)
            #else
            return nil
            #endif
        case .appGroup(let id):
            #if canImport(Darwin)
            return manager.containerURL(forSecurityApplicationGroupIdentifier: id)
            #else
            return nil
            #endif
        case .applicationSupport:
            return manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SwiftRecords", isDirectory: true)
        case .other(let directory):
            return directory
        }
    }

    // MARK: SyncProvider

    /// The location, so moving to another folder uploads everything to it.
    public var identifier: String { "FileSyncProvider.\(location)" }

    public func userID() async throws -> String? {
        guard location.isICloud else { return "local" }
        #if canImport(Darwin)
        // The token changes with the iCloud account, and is nil while signed out.
        guard let token = FileManager.default.ubiquityIdentityToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else {
            return nil
        }
        return Self.hash(data)
        #else
        return nil
        #endif
    }

    public func uploadRecordChanges(_ changes: [RecordChangeData]) async throws -> [UploadResult] {
        let root = try root()
        defer { mark(Set(changes.map(\.zone)), in: root) }
        return try lock.withLock {
            try changes.map { change in
                let file = Self.recordFile(change.type, change.id, in: root.appendingPathComponent(change.zone.name))
                let current = try Self.read(file)
                if !change.isDeletion, let current, current.metadata.changeTag != change.metadata.changeTag {
                    return .conflict(current)
                }
                // Each save gets a strictly later date, and its milliseconds are the new tag.
                let stamp = Self.stamp(after: current?.metadata.modified)
                var stored = change
                stored.metadata.changeTag = String(Self.milliseconds(stamp))
                stored.metadata.modified = stamp
                stored.metadata.created = current?.metadata.created ?? stamp
                stored.metadata.creator = current?.metadata.creator ?? change.metadata.creator
                try Self.write(stored, to: file)
                return .saved(id: change.id, metadata: stored.metadata)
            }
        }
    }

    public func downloadRecordChanges(in zone: Zone, after cursor: Data?) async throws -> RecordDownload {
        let folder = try root().appendingPathComponent(zone.name, isDirectory: true)
        var state = cursor.flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) } ?? Cursor()
        let epoch = try Self.epoch(of: folder)
        if let seen = state.epoch, seen != epoch {
            throw SyncError.serverReset
        }
        state.epoch = epoch
        var found: [(key: String, change: RecordChangeData)] = []
        for file in Self.recordFiles(in: folder) {
            guard let change = try? Self.read(file), let tag = change.metadata.changeTag else { continue }
            let key = "\(change.type)/\(change.id)"
            if state.seen[key] != tag {
                found.append((key, change))
            }
        }
        found.sort {
            ($0.change.metadata.modified ?? .distantPast, $0.key) < ($1.change.metadata.modified ?? .distantPast, $1.key)
        }
        let page = found.prefix(Self.pageSize)
        for (key, change) in page {
            state.seen[key] = change.metadata.changeTag
        }
        return RecordDownload(
            changes: page.map { $0.change }, cursor: try JSONEncoder().encode(state), hasMore: found.count > page.count
        )
    }

    public func uploadAssets(_ assets: [RecordAssetData]) async throws {
        let root = try root()
        defer { mark(Set(assets.map(\.zone)), in: root) }
        let manager = FileManager.default
        for asset in assets {
            let folder = root.appendingPathComponent(asset.zone.name).appendingPathComponent(Self.assetsFolder, isDirectory: true)
            let destination = folder.appendingPathComponent(asset.id)
            // A file never changes once stored.
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try Self.mapping {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.coordinate(writing: destination) { url in
                    let partial = folder.appendingPathComponent(".\(asset.id).partial")
                    try? manager.removeItem(at: partial)
                    try manager.copyItem(at: asset.file, to: partial)
                    try manager.moveItem(at: partial, to: url)
                }
            }
        }
    }

    public func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL {
        let source = try root().appendingPathComponent(zone.name)
            .appendingPathComponent(Self.assetsFolder, isDirectory: true).appendingPathComponent(id)
        let destination = directory.appendingPathComponent(id)
        guard Self.isAvailable(source) else { throw SyncError.offline }
        try Self.coordinate(reading: source) { url in
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return destination
    }

    public func pushedChanges() -> AsyncStream<[Zone]>? {
        let (stream, continuation) = AsyncStream<[Zone]>.makeStream()
        let id = UUID()
        lock.withLock { pushes[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.removePushes(id)
        }
        startWatching()
        return stream
    }

    // MARK: Watching

    private static let markFile = "_changed"

    private func removePushes(_ id: UUID) {
        lock.withLock { pushes[id] = nil }
    }

    private func send(_ zones: Set<Zone>) {
        guard !zones.isEmpty else { return }
        let sorted = zones.sorted { $0.name < $1.name }
        for continuation in lock.withLock({ Array(pushes.values) }) {
            continuation.yield(sorted)
        }
    }

    private func startWatching() {
        let start = lock.withLock {
            defer { watching = true }
            return !watching
        }
        guard start else { return }
        if location.isICloud {
            #if canImport(Darwin)
            let scope = location == .iCloudDrive ? NSMetadataQueryUbiquitousDocumentsScope : NSMetadataQueryUbiquitousDataScope
            let watcher = MetadataWatcher(scope: scope) { [weak self] paths in
                guard let self, let root = self.directory else { return }
                self.send(Self.zones(forPaths: paths, under: root))
            }
            lock.withLock { query = watcher }
            #endif
        } else if let interval = watchInterval {
            let task = Task { [weak self] in
                // The first check also pushes whatever changed before watching began.
                var last: [Zone: String] = [:]
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self else { return }
                    let now = self.marks()
                    let own = self.lock.withLock { self.ownMarks }
                    let changed = now.filter { last[$0.key] != $0.value && !own.contains($0.value) }
                    last = now
                    self.send(Set(changed.keys))
                }
            }
            lock.withLock { poller = task }
        }
    }

    /// Leaves a fresh mark in each zone written to, which other devices' watchers notice.
    private func mark(_ zones: Set<Zone>, in root: URL) {
        for zone in zones {
            let token = UUID().uuidString
            lock.withLock { _ = ownMarks.insert(token) }
            let file = root.appendingPathComponent(zone.name).appendingPathComponent(Self.markFile)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.coordinate(writing: file) { url in
                try Data(token.utf8).write(to: url, options: .atomic)
            }
        }
    }

    /// Each zone folder's latest mark.
    private func marks() -> [Zone: String] {
        guard let root = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [:] }
        var marks: [Zone: String] = [:]
        for name in names {
            guard let zone = Self.zone(named: name),
                  let data = try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent(Self.markFile)) else {
                continue
            }
            marks[zone] = String(decoding: data, as: UTF8.self)
        }
        return marks
    }

    /// The zones that files at these paths belong to, from the folder each sits in under `root`.
    static func zones(forPaths paths: [String], under root: URL) -> Set<Zone> {
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var zones: Set<Zone> = []
        for path in paths {
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(prefix),
                  let first = resolved.dropFirst(prefix.count).split(separator: "/").first,
                  let zone = zone(named: String(first)) else { continue }
            zones.insert(zone)
        }
        return zones
    }

    private static func zone(named name: String) -> Zone? {
        [Zone.default, .inMemory, .localOnly].first { $0.name == name } ?? (try? Zone(name))
    }

    // MARK: Conflicting versions

    /// Settles the versions iCloud kept when devices wrote a record file at once. The copy with the later
    /// `modified` date stays.
    private static func resolveConflicts(at file: URL) {
        #if canImport(Darwin)
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: file), !conflicts.isEmpty else { return }
        let current = try? decode(Data(contentsOf: file))
        let others = conflicts.map { try? decode(Data(contentsOf: $0.url)) }
        let best = newest([current] + others)
        try? coordinate(writing: file) { url in
            if best > 0 {
                _ = try conflicts[best - 1].replaceItem(at: url, options: [])
            }
            for conflict in conflicts {
                conflict.isResolved = true
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        #endif
    }

    /// The index of the copy to keep: the latest `modified` date, and the first of any tie.
    static func newest(_ copies: [RecordChangeData?]) -> Int {
        var best = 0
        var bestDate = Int64.min
        for (index, copy) in copies.enumerated() {
            let date = copy?.metadata.modified.map(Self.milliseconds) ?? Int64.min
            if date > bestDate {
                best = index
                bestDate = date
            }
        }
        return best
    }

    // MARK: Files

    private static let pageSize = 500
    private static let assetsFolder = "_assets"
    private static let epochFile = "_zone.json"

    /// Every record file seen, by type and ID, with the change tag it was seen at.
    private struct Cursor: Codable {
        var epoch: String?
        var seen: [String: String] = [:]
    }

    private func root() throws -> URL {
        guard let directory else { throw SyncError.offline }
        return directory
    }

    private static func recordFile(_ type: String, _ id: UUID, in zone: URL) -> URL {
        zone.appendingPathComponent(type, isDirectory: true).appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    /// The record files in a zone's folder. Files iCloud hasn't downloaded yet are asked for and skipped.
    private static func recordFiles(in zone: URL) -> [URL] {
        let manager = FileManager.default
        guard let types = try? manager.contentsOfDirectory(at: zone, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for type in types where !type.lastPathComponent.hasPrefix("_") && !type.lastPathComponent.hasPrefix(".") {
            guard let names = try? manager.contentsOfDirectory(atPath: type.path) else { continue }
            for name in names {
                if name.hasSuffix(".json"), !name.hasPrefix(".") {
                    files.append(type.appendingPathComponent(name))
                } else if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                    startDownloading(type.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count))))
                }
            }
        }
        return files
    }

    /// Whether a file is here, asking iCloud for it when it isn't yet.
    private static func isAvailable(_ file: URL) -> Bool {
        if FileManager.default.fileExists(atPath: file.path) { return true }
        startDownloading(file)
        return false
    }

    private static func startDownloading(_ file: URL) {
        #if canImport(Darwin)
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        #endif
    }

    /// A zone folder's identity. A new folder, as after someone deletes the old one, gets a new one.
    private static func epoch(of zone: URL) throws -> String {
        let file = zone.appendingPathComponent(epochFile)
        // A folder whose identity iCloud hasn't downloaded yet isn't new.
        if FileManager.default.fileExists(atPath: zone.appendingPathComponent(".\(epochFile).icloud").path) {
            startDownloading(file)
            throw SyncError.offline
        }
        if let data = try? coordinatedData(at: file),
           let epoch = try? JSONDecoder().decode([String: String].self, from: data)["epoch"] {
            return epoch
        }
        let epoch = UUID().uuidString
        try mapping {
            try FileManager.default.createDirectory(at: zone, withIntermediateDirectories: true)
            try coordinate(writing: file) { url in
                try JSONEncoder().encode(["epoch": epoch]).write(to: url, options: .atomic)
            }
        }
        return epoch
    }

    /// A whole-millisecond date strictly after `previous`, so each accepted change gets a later one than
    /// the copy it replaced. Whole milliseconds survive every conversion a date goes through unchanged.
    private static func stamp(after previous: Date?) -> Date {
        let now = milliseconds(Date())
        let next = previous.map { max(now, milliseconds($0) + 1) } ?? now
        return date(milliseconds: next)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    // A record file holds the change's fields under "record", so it reads like the record.
    private static func read(_ file: URL) throws -> RecordChangeData? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        resolveConflicts(at: file)
        return try decode(try coordinatedData(at: file))
    }

    /// A record file: the change, with its metadata named as a `CKRecord`'s system fields are and dates as
    /// milliseconds since 1970.
    private struct RecordFile: Codable {
        var id: UUID
        var zone: Zone
        var type: String
        var changeTag: String?
        var created: Int64?
        var modified: Int64?
        var creator: String?
        var lastModifier: String?
        var record: [String: RecordValue]?
    }

    private static let fileEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let fileDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func decode(_ data: Data) throws -> RecordChangeData {
        let file = try fileDecoder.decode(RecordFile.self, from: data)
        let metadata = SyncMetadata(
            // A hand-written file may carry only its date, which then serves as its tag.
            changeTag: file.changeTag ?? file.modified.map { String($0) }, created: file.created.map { date(milliseconds: $0) },
            modified: file.modified.map { date(milliseconds: $0) }, creator: file.creator, lastModifier: file.lastModifier
        )
        return RecordChangeData(id: file.id, zone: file.zone, type: file.type, fields: file.record, metadata: metadata)
    }

    private static func write(_ change: RecordChangeData, to file: URL) throws {
        let data = try fileEncoder.encode(RecordFile(
            id: change.id, zone: change.zone, type: change.type, changeTag: change.metadata.changeTag,
            created: change.metadata.created.map(milliseconds), modified: change.metadata.modified.map(milliseconds),
            creator: change.metadata.creator, lastModifier: change.metadata.lastModifier, record: change.fields
        ))
        try mapping {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinate(writing: file) { url in
                try data.write(to: url, options: .atomic)
            }
        }
    }

    private static func coordinatedData(at file: URL) throws -> Data {
        var data = Data()
        try coordinate(reading: file) { url in
            data = try Data(contentsOf: url)
        }
        return data
    }

    // iCloud asks that reads and writes in its folders go through a file coordinator.
    private static func coordinate(reading file: URL, _ body: (URL) throws -> Void) throws {
        #if canImport(Darwin)
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
        #else
        try body(file)
        #endif
    }

    private static func coordinate(writing file: URL, _ body: (URL) throws -> Void) throws {
        #if canImport(Darwin)
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
        #else
        try body(file)
        #endif
    }

    /// Turns a full disk into `storageFull`.
    private static func mapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw SyncError.storageFull
        }
    }

    /// A short stable name for an account token, without a crypto dependency.
    private static func hash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

extension FileSyncProvider.Location {
    var isICloud: Bool {
        switch self {
        case .iCloud, .iCloudDrive: true
        default: false
        }
    }
}

#if canImport(Darwin)
/// Watches an iCloud scope and reports the paths of files that arrive, change or leave, including when a
/// file another device wrote finishes downloading.
final class MetadataWatcher: NSObject, @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let changed: @Sendable ([String]) -> Void

    init(scope: String, changed: @escaping @Sendable ([String]) -> Void) {
        self.changed = changed
        super.init()
        query.searchScopes = [scope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        NotificationCenter.default.addObserver(self, selector: #selector(update(_:)), name: .NSMetadataQueryDidUpdate, object: query)
        // A query needs a run loop, so it lives on the main one.
        DispatchQueue.main.async { self.query.start() }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        DispatchQueue.main.async { self.query.stop() }
    }

    @objc private func update(_ notification: Notification) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var paths: [String] = []
        for key in [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey, NSMetadataQueryUpdateRemovedItemsKey] {
            for item in notification.userInfo?[key] as? [NSMetadataItem] ?? [] {
                if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                    paths.append(path)
                }
            }
        }
        changed(paths)
    }
}
#endif
