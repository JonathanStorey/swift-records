import Foundation
import SwiftRecords

/// Syncs through a folder of files, such as the app's iCloud container, which the system then copies
/// between the person's devices. No server code is needed.
///
/// ```swift
/// let engine = PollingSyncEngine(transport: FileSyncTransport())
/// let container = try RecordContainer(for: [Recipe.self], syncProvider: engine)
/// ```
///
/// Each record is one readable JSON file, at `Records/<zone>/<type>/<id>.json`, and each asset is a plain
/// file in `Records/<zone>/_assets/`. A deletion stays behind as a small file so other devices hear of it.
/// Downloads remember every file they have seen rather than a time, so devices whose clocks disagree
/// can't miss each other's changes. Deleting a zone's folder deletes the zone, and its records leave
/// every device.
///
/// Other devices' changes arrive without a refresh. In iCloud an `NSMetadataQuery` watches the folder, and
/// App Group and other folders are watched for changes. A network drive may not report its changes, so
/// they arrive with the sync the context runs as the app returns from a break, or a manual one.
/// Application Support has no other writer, so it isn't watched. When iCloud keeps two versions of a
/// record file because devices wrote it at once, `NSFileVersion` settles them: the copy with the later
/// `synced` time stays, as a whole record.
///
/// iCloud needs the iCloud capability with iCloud Documents turned on. While the person is signed out of
/// iCloud, the container reports `signedOut`.
///
/// Sharing a zone hands out its folder's URL. Whoever opens that URL from their own `FileSyncTransport`,
/// such as through a shared network drive or App Group, joins the zone and syncs it in place. A shared
/// folder isn't watched, so its changes arrive with the next sync.
public final class FileSyncTransport: SyncTransport, AssetTransfer, ZoneSharing, @unchecked Sendable {
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
    /// How this provider hears of other writers' changes, chosen by location. Tests change it.
    var watchMode: WatchMode
    private var resolved: URL??
    private var pushes: [UUID: AsyncStream<[Zone]>.Continuation] = [:]
    private var watching = false
    private var poller: Task<Void, Never>?
    /// Each zone's mark as of the last check, to tell new ones apart.
    private var lastMarks: [Zone: String] = [:]
    #if canImport(Darwin)
    private var folderSource: DispatchSourceFileSystemObject?
    #endif
    /// Change marks this provider wrote, which its own watcher ignores.
    private var ownMarks: Set<String> = []
    #if canImport(Darwin)
    private var query: MetadataWatcher?
    #endif

    public init(location: Location = .iCloud) {
        self.location = location
        watchMode = switch location {
        case .iCloud, .iCloudDrive: .metadata
        case .appGroup, .other: .folder
        case .applicationSupport: .none
        }
    }

    deinit {
        poller?.cancel()
        #if canImport(Darwin)
        query?.stop()
        folderSource?.cancel()
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

    // MARK: SyncTransport

    /// The location, so moving to another folder uploads everything to it.
    public var identifier: String { "FileSyncTransport.\(location)" }

    public func currentUser() async throws -> String? {
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

    public var scopes: Set<Zone.Scope> { [.private, .shared] }

    public func modifyRecords(_ batch: RecordBatch) async throws -> SentRecordChanges {
        let root = try root()
        let changes = batch.changes
        defer { mark(Set(changes.map(\.zone)), in: root) }
        var folders: [Zone: URL] = [:]
        for zone in Set(changes.map(\.zone)) {
            folders[zone] = try? folder(for: zone, in: root)
        }
        return try lock.withLock {
            var result = SentRecordChanges()
            for change in changes {
                // A zone shared with the person can be written only while its owner shares it.
                guard let folder = folders[change.zone], change.zone.scope == .private || Self.shareFile(in: folder) != nil else {
                    result.failed.append(FailedSave(change: change, failure: .permissionFailure))
                    continue
                }
                let file = Self.recordFile(change.type, change.id, in: folder)
                let current = try Self.read(file).map { Self.seen($0, in: change.zone) }
                if !change.isDeletion, let current, current.tag != change.tag {
                    result.failed.append(FailedSave(change: change, failure: .serverRecordChanged(current)))
                    continue
                }
                // Each save gets a strictly later time, and its milliseconds are the new tag. The file names
                // the zone as its owner sees it.
                var stored = change
                stored.synced = Self.stamp(after: current?.synced)
                stored.tag = stored.synced.map(Self.tag)
                stored.zone = (try? Zone(change.zone.name)) ?? change.zone
                try Self.write(stored, to: file)
                if change.isDeletion {
                    result.deleted.append(RecordDeletion(id: change.id, zone: change.zone, type: change.type))
                } else {
                    result.saved.append(Self.seen(stored, in: change.zone))
                }
            }
            return result
        }
    }

    /// A stored change as the person reading it names its zone.
    private static func seen(_ change: RecordChangeData, in zone: Zone) -> RecordChangeData {
        var change = change
        change.zone = zone
        return change
    }

    /// Every zone folder, so each is checked for new files, and the zones whose folders were deleted or
    /// replaced since `token`, which holds each folder's identity.
    public func fetchDatabaseChanges(_ scope: Zone.Scope, since token: Data?) async throws -> DatabaseChanges {
        let root = try root()
        if scope == .shared {
            return try sharedDatabaseChanges(in: root, since: token)
        }
        let known = token.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var epochs: [String: String] = [:]
        var modified: [Zone] = []
        for name in names.sorted() {
            guard let zone = Self.zone(named: name) else { continue }
            epochs[name] = try Self.epoch(of: root.appendingPathComponent(name, isDirectory: true))
            modified.append(zone)
        }
        let deleted = known.compactMap { name, epoch -> ZoneDeletion? in
            guard epochs[name] != epoch, let zone = Self.zone(named: name) else { return nil }
            return ZoneDeletion(zone: zone, reason: .deleted)
        }
        return DatabaseChanges(modified: modified, deleted: deleted.sorted { $0.zone.name < $1.zone.name }, token: try JSONEncoder().encode(epochs))
    }

    public func fetchZoneChanges(_ zone: Zone, since token: Data?) async throws -> ZoneChanges {
        let folder = try folder(for: zone, in: root())
        var state = token.flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) } ?? Cursor()
        var found: [(key: String, change: RecordChangeData)] = []
        for file in Self.recordFiles(in: folder) {
            guard let change = try? Self.read(file).map({ Self.seen($0, in: zone) }), let tag = change.tag else { continue }
            let key = "\(change.type)/\(change.id)"
            if state.seen[key] != tag {
                found.append((key, change))
            }
        }
        found.sort {
            ($0.change.synced ?? .distantPast, $0.key) < ($1.change.synced ?? .distantPast, $1.key)
        }
        let page = found.prefix(Self.pageSize)
        for (key, change) in page {
            state.seen[key] = change.tag
        }
        let changes = page.map(\.change)
        return ZoneChanges(
            saved: changes.filter { !$0.isDeletion },
            deleted: changes.filter(\.isDeletion).map { RecordDeletion(id: $0.id, zone: $0.zone, type: $0.type) },
            token: try JSONEncoder().encode(state), moreComing: found.count > page.count
        )
    }

    public func uploadAssets(_ assets: [RecordAssetData]) async throws {
        let root = try root()
        defer { mark(Set(assets.map(\.zone)), in: root) }
        let manager = FileManager.default
        for asset in assets {
            let folder = try folder(for: asset.zone, in: root).appendingPathComponent(Self.assetsFolder, isDirectory: true)
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
        let source = try folder(for: zone, in: root())
            .appendingPathComponent(Self.assetsFolder, isDirectory: true).appendingPathComponent(id)
        let destination = directory.appendingPathComponent(id)
        guard Self.isAvailable(source) else { throw SyncFailure.networkUnavailable }
        try Self.coordinate(reading: source) { url in
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return destination
    }

    public func changeNotifications() -> AsyncStream<[Zone]>? {
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
    /// A mark beside the zone folders, rewritten with every zone's, so one folder watch hears them all. Its
    /// leading dot keeps it from reading as a zone.
    private static let rootMarkFile = ".changed"

    /// How a provider hears of changes other writers make to its folder.
    enum WatchMode: Equatable {
        /// An `NSMetadataQuery` reports iCloud's downloads.
        case metadata
        /// The folder itself is watched, for an app and its extensions, or a shared or network folder.
        case folder
        /// The folder is checked on a timer, for tests on platforms without folder watching.
        case poll(Duration)
        /// Nothing else writes the folder.
        case none
    }

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
        switch watchMode {
        case .metadata:
            #if canImport(Darwin)
            let scope = location == .iCloudDrive ? NSMetadataQueryUbiquitousDocumentsScope : NSMetadataQueryUbiquitousDataScope
            let watcher = MetadataWatcher(scope: scope) { [weak self] paths in
                guard let self, let root = self.directory else { return }
                self.send(Self.zones(forPaths: paths, under: root))
            }
            lock.withLock { query = watcher }
            #endif
        case .folder:
            #if canImport(Darwin)
            guard let root = directory else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let descriptor = open(root.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global())
            source.setEventHandler { [weak self] in self?.checkMarks() }
            source.setCancelHandler { close(descriptor) }
            lock.withLock { folderSource = source }
            source.resume()
            // Pushes whatever changed before watching began.
            checkMarks()
            #endif
        case .poll(let interval):
            poll(every: interval)
        case .none:
            break
        }
    }

    private func poll(every interval: Duration) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.checkMarks()
            }
        }
        lock.withLock { poller = task }
    }

    /// Pushes the zones whose marks changed since the last check, other than this provider's own.
    private func checkMarks() {
        let now = marks()
        let changed = lock.withLock {
            defer { lastMarks = now }
            return now.filter { lastMarks[$0.key] != $0.value && !ownMarks.contains($0.value) }
        }
        send(Set(changed.keys))
    }

    /// Leaves a fresh mark in each zone written to, which other devices' watchers notice.
    private func mark(_ zones: Set<Zone>, in root: URL) {
        for zone in zones {
            let token = UUID().uuidString
            lock.withLock { _ = ownMarks.insert(token) }
            guard let folder = try? folder(for: zone, in: root) else { continue }
            let file = folder.appendingPathComponent(Self.markFile)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.coordinate(writing: file) { url in
                try Data(token.utf8).write(to: url, options: .atomic)
            }
        }
        guard !zones.isEmpty else { return }
        try? Data(UUID().uuidString.utf8).write(to: root.appendingPathComponent(Self.rootMarkFile), options: .atomic)
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
        Zone(stored: name)
    }

    // MARK: Conflicting versions

    /// Settles the versions iCloud kept when devices wrote a record file at once. The copy with the later
    /// `synced` time stays.
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

    /// The index of the copy to keep: the latest `synced` time, and the first of any tie.
    static func newest(_ copies: [RecordChangeData?]) -> Int {
        var best = 0
        var bestDate = Int64.min
        for (index, copy) in copies.enumerated() {
            let date = copy?.synced.map(Self.milliseconds) ?? Int64.min
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
        var seen: [String: Data] = [:]
    }

    private func root() throws -> URL {
        guard let directory else { throw SyncFailure.networkUnavailable }
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
            throw SyncFailure.networkUnavailable
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

    /// A record file: the change, with the time it was saved in milliseconds since 1970, which is also its tag.
    private struct RecordFile: Codable {
        var id: UUID
        var zone: Zone
        var type: String
        var synced: Int64?
        var record: [String: RecordValue]?
    }

    /// A save time's tag: its milliseconds, as text.
    private static func tag(_ date: Date) -> Data {
        Data(String(milliseconds(date)).utf8)
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
        let synced = file.synced.map { date(milliseconds: $0) }
        return RecordChangeData(id: file.id, zone: file.zone, type: file.type, fields: file.record, tag: synced.map(tag), synced: synced)
    }

    private static func write(_ change: RecordChangeData, to file: URL) throws {
        let data = try fileEncoder.encode(RecordFile(
            id: change.id, zone: change.zone, type: change.type, synced: change.synced.map(milliseconds), record: change.fields
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

    /// Turns a full disk into `quotaExceeded`.
    private static func mapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw SyncFailure.quotaExceeded
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

// MARK: - Sharing

extension FileSyncTransport {
    /// A zone folder's share, beside its records.
    struct ShareFile: Codable, Hashable {
        /// The owner's account, from `.account.json` beside their zone folders.
        var owner: String
        /// Everyone who joined, by account.
        var participants: [String]
    }

    /// A zone someone shared with the person, and where its folder is.
    struct JoinedZone: Codable, Hashable {
        var owner: String
        var zone: String
        var path: String

        var key: String { "\(owner)/\(zone)" }
    }

    private static let shareFileName = "_share.json"
    private static let accountFile = ".account.json"
    private static let joinedFile = ".shares.json"

    /// The folder a zone's files live in: the person's own, or the owner's for a zone shared with them.
    func folder(for zone: Zone, in root: URL) throws -> URL {
        guard let owner = zone.owner else { return root.appendingPathComponent(zone.name, isDirectory: true) }
        guard let joined = Self.joined(in: root).first(where: { $0.owner == owner && $0.zone == zone.name }) else {
            throw SyncFailure.zoneNotFound
        }
        return URL(fileURLWithPath: joined.path, isDirectory: true)
    }

    static func shareFile(in folder: URL) -> ShareFile? {
        let file = folder.appendingPathComponent(shareFileName)
        guard FileManager.default.fileExists(atPath: file.path), let data = try? coordinatedData(at: file) else { return nil }
        return try? JSONDecoder().decode(ShareFile.self, from: data)
    }

    private static func writeShareFile(_ share: ShareFile?, in folder: URL) throws {
        let file = folder.appendingPathComponent(shareFileName)
        guard let share else {
            try? coordinate(writing: file) { url in try FileManager.default.removeItem(at: url) }
            return
        }
        let data = try fileEncoder.encode(share)
        try mapping {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try coordinate(writing: file) { url in try data.write(to: url, options: .atomic) }
        }
    }

    /// The account these zone folders belong to, made the first time it's needed. It travels with the
    /// folder, so every device of the person's has the same one.
    private static func account(in root: URL) throws -> String {
        let file = root.appendingPathComponent(accountFile)
        if let data = try? coordinatedData(at: file), let id = try? JSONDecoder().decode([String: String].self, from: data)["id"] {
            return id
        }
        let id = UUID().uuidString.lowercased()
        let data = try fileEncoder.encode(["id": id])
        try mapping {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try coordinate(writing: file) { url in try data.write(to: url, options: .atomic) }
        }
        return id
    }

    static func joined(in root: URL) -> [JoinedZone] {
        guard let data = try? coordinatedData(at: root.appendingPathComponent(joinedFile)) else { return [] }
        return (try? JSONDecoder().decode([JoinedZone].self, from: data)) ?? []
    }

    private static func setJoined(_ zones: [JoinedZone], in root: URL) throws {
        let data = try fileEncoder.encode(zones.sorted { $0.key < $1.key })
        try mapping {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try coordinate(writing: root.appendingPathComponent(joinedFile)) { url in try data.write(to: url, options: .atomic) }
        }
    }

    /// The zones shared with the person. One whose owner stopped sharing it is deleted, and so is one the
    /// person left. One whose folder can't be reached now waits, rather than losing its records.
    func sharedDatabaseChanges(in root: URL, since token: Data?) throws -> DatabaseChanges {
        let known = Set(token.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        var joined = Self.joined(in: root)
        var modified: [Zone] = []
        var deleted: [ZoneDeletion] = []
        var current: Set<String> = []
        for entry in joined {
            guard let zone = try? Zone(entry.zone, sharedBy: entry.owner) else { continue }
            let folder = URL(fileURLWithPath: entry.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                if known.contains(entry.key) { current.insert(entry.key) }
                continue
            }
            if Self.shareFile(in: folder) == nil {
                deleted.append(ZoneDeletion(zone: zone, reason: .deleted))
            } else {
                current.insert(entry.key)
                modified.append(zone)
            }
        }
        for key in known.subtracting(current) where !deleted.contains(where: { "\($0.zone.owner ?? "")/\($0.zone.name)" == key }) {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let zone = try? Zone(parts[1], sharedBy: parts[0]) {
                deleted.append(ZoneDeletion(zone: zone, reason: .deleted))
            }
        }
        // A share that ended is forgotten, so joining again starts over.
        if deleted.contains(where: { zone in joined.contains { $0.key == "\(zone.zone.owner ?? "")/\(zone.zone.name)" } }) {
            joined.removeAll { entry in deleted.contains { "\($0.zone.owner ?? "")/\($0.zone.name)" == entry.key } }
            try Self.setJoined(joined, in: root)
        }
        return DatabaseChanges(modified: modified, deleted: deleted, token: try JSONEncoder().encode(current.sorted()))
    }

    // MARK: ZoneSharing

    /// Shares the zone's folder. The invitation is its file URL, which works wherever the people joining
    /// reach the same folder.
    public func share(_ zone: Zone) async throws -> ZoneShare {
        let root = try root()
        let folder = try folder(for: zone, in: root)
        if Self.shareFile(in: folder) == nil {
            _ = try Self.epoch(of: folder)
            try Self.writeShareFile(ShareFile(owner: try Self.account(in: root), participants: []), in: folder)
        }
        return try await existingShare(for: zone) ?? ZoneShare(zone: zone, url: folder, participants: [])
    }

    public func existingShare(for zone: Zone) async throws -> ZoneShare? {
        let folder = try folder(for: zone, in: root())
        guard let share = Self.shareFile(in: folder) else { return nil }
        let participants = [ShareParticipant(id: share.owner, role: .owner, status: .accepted)]
            + share.participants.map { ShareParticipant(id: $0, role: .participant, status: .accepted) }
        return ZoneShare(zone: zone, url: folder, participants: participants)
    }

    public func acceptShare(_ invitation: URL) async throws -> Zone {
        let root = try root()
        let folder = invitation.standardizedFileURL
        guard invitation.isFileURL, var share = Self.shareFile(in: folder), let zone = Self.zone(named: folder.lastPathComponent) else {
            throw SyncFailure.zoneNotFound
        }
        let me = try Self.account(in: root)
        guard share.owner != me else { throw SyncFailure.other("This zone is already the person's own") }
        if !share.participants.contains(me) {
            share.participants.append(me)
            try Self.writeShareFile(share, in: folder)
        }
        let entry = JoinedZone(owner: share.owner, zone: zone.name, path: folder.path)
        var joined = Self.joined(in: root).filter { $0.key != entry.key }
        joined.append(entry)
        try Self.setJoined(joined, in: root)
        return try Zone(zone.name, sharedBy: share.owner)
    }

    public func stopSharing(_ zone: Zone) async throws {
        let root = try root()
        let folder = try folder(for: zone, in: root)
        guard zone.scope == .shared else {
            try Self.writeShareFile(nil, in: folder)
            return
        }
        let me = try Self.account(in: root)
        if var share = Self.shareFile(in: folder) {
            share.participants.removeAll { $0 == me }
            try Self.writeShareFile(share, in: folder)
        }
        try Self.setJoined(Self.joined(in: root).filter { !($0.owner == zone.owner && $0.zone == zone.name) }, in: root)
    }
}

extension FileSyncTransport.Location {
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
