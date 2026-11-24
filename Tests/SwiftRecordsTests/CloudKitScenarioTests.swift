#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import SwiftRecords
import Versioning

// Two or more devices syncing through a stand-in for the CloudKit server, driven the way
// CKSyncEngine drives the container: fetched changes go to `save(their:)` and
// `save(deleted:)`, pending changes go out through `send(id:)` and `send(deleted:)`, and
// the server's answers come back to `save(sent:)` and `save(failed:error:)`.

private struct Folder: Identifiable {
    var id: UUID
}

private struct Size: Codable, Equatable {
    var width: Double
    var height: Double
}

/// A counter both devices can raise at once: the increases add.
private struct Views: RawRepresentable, Codable, Equatable, Mergeable {
    var rawValue: Int

    func merging(with theirs: Views, from base: Views) throws(MergeConflict) -> Views {
        try merging(with: theirs, from: base, using: .rawValue(.sum()))
    }
}

/// A record with each kind of CloudKit field: plain, list, nested JSON, encrypted, asset,
/// reference, and a value with its own merge.
private struct Draft: Codable, Equatable, Identifiable, Mergeable {
    var id: UUID
    var title = "Untitled"
    var body = ""
    var subtitle: String? = "Subtitle"
    var tags = ["a"]
    var size = Size(width: 1, height: 2)
    var views = Views(rawValue: 0)
    @Encrypted var secret = "secret"
    @Encrypted var pin: Int? = 1234
    @Asset var attachment: Data? = nil
    @Reference<Folder> var folder: Folder.ID? = nil

    /// This draft without the attachment's file, which each device keeps in its own place.
    var withoutFile: Draft {
        var draft = self
        draft.$attachment = nil
        return draft
    }
}

/// An append-only drawing: each side's new strokes follow the base's.
private struct Drawing: RawRepresentable, Equatable, Mergeable {
    var rawValue: Data

    func merging(with theirs: Drawing, from base: Drawing) throws(MergeConflict) -> Drawing {
        Drawing(rawValue: rawValue + theirs.rawValue.dropFirst(base.rawValue.count))
    }
}

private struct Sketch: Codable, Identifiable, Mergeable {
    var id: UUID
    @Asset var drawing: Drawing? = nil
}

/// A record for the public database, which cannot hold encrypted values.
private struct Post: Codable, Equatable, Identifiable, Mergeable {
    var id: UUID
    var text = ""
    var likes = Views(rawValue: 0)
}

/// The same record type as two versions of the app see it.
private enum Older {
    struct Draft: Codable, Identifiable, Mergeable {
        var id: UUID
        var title = "Untitled"
    }
}

private enum Newer {
    struct Draft: Codable, Identifiable, Mergeable {
        var id: UUID
        var title = "Untitled"
        var color: String? = nil
    }
}

/// A record named by a slug, so two devices that create it apart name the same record.
private struct Page: Codable, Equatable, Identifiable, Mergeable {
    var id: String
    var title = ""
    var body = ""
}

/// A seeded generator, so a randomized run can be replayed: SplitMix64.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

private enum Incompatible {
    struct Draft: Codable, Identifiable, Mergeable {
        var id: UUID
        var title: Int
    }
}

/// The server: each record with the version it was last saved at, and a tombstone for
/// each deleted one.
private final class Server {
    var records: [CKRecord.ID: (record: CKRecord, version: Int)] = [:]
    var tombstones: [CKRecord.ID: Int] = [:]
    var clock = 0
    let files = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: files)
    }

    /// Saves `sent` as CloudKit does: only the fields set on it change, and each asset is
    /// copied in. Returns the record the way an upload confirms it, holding only what was sent.
    func save(_ sent: CKRecord) throws -> CKRecord {
        let stored = (records[sent.recordID]?.record.copy() as? CKRecord) ?? CKRecord(recordType: sent.recordType, recordID: sent.recordID)
        for key in sent.changedKeys() {
            if let value = sent.encryptedValues[key] {
                stored.encryptedValues[key] = value
            } else if stored.encryptedValues.allKeys().contains(key) {
                stored.encryptedValues[key] = nil
            } else if let asset = sent[key] as? CKAsset, let file = asset.fileURL {
                try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                let copy = files.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: file, to: copy)
                stored[key] = CKAsset(fileURL: copy)
            } else {
                stored[key] = sent[key]
            }
        }
        clock += 1
        records[sent.recordID] = (stored, clock)
        tombstones[sent.recordID] = nil
        return sent
    }

    func delete(_ id: CKRecord.ID) {
        clock += 1
        records[id] = nil
        tombstones[id] = clock
    }

    /// Loses every record in the zone, as an encrypted data reset or a purge does, with no tombstones.
    func lose(zone: CKRecordZone.ID) {
        records = records.filter { $0.key.zoneID != zone }
    }

    /// The stored record `id` decoded as `type`.
    func value<T: Decodable>(_ type: T.Type, id: String, zone: Zone = "Drafts") throws -> T? {
        guard let record = records[CKRecord.ID(recordName: id, zoneID: zone.zoneID)]?.record else { return nil }
        return try CKRecordDecoder().decode(type, from: record)
    }

    func value<T: Decodable>(_ type: T.Type, id: UUID, zone: Zone = "Drafts") throws -> T? {
        try value(type, id: id.uuidString, zone: zone)
    }
}

/// A device: its container, and what it last heard from the server.
private final class Device {
    let container: RecordContainer
    let server: Server
    /// The server version of each record this device last fetched or saved.
    var known: [CKRecord.ID: Int] = [:]
    /// The server clock as of the last fetch, kept as the engine's state in the container,
    /// so it outlives a launch and is lost wherever the container clears that state.
    var cursor: Int {
        get { container.engineStateData.flatMap { try? JSONDecoder().decode(Int.self, from: $0) } ?? 0 }
        set { container.engineStateData = try? JSONEncoder().encode(newValue) }
    }
    /// What the last upload sent, by record.
    var lastSent: [CKRecord.ID: CKRecord] = [:]

    /// The database file, kept across launches, or `nil` for a device that keeps it in memory.
    let url: URL?

    init(_ server: Server, registering types: [any Codable.Type] = [Draft.self], url: URL? = nil) {
        self.server = server
        self.url = url
        container = url.map { try! RecordContainer(for: types, url: $0) } ?? RecordContainer.inMemory(types)
    }

    /// A device that keeps its database in a new file, so it can be launched again.
    static func onDisk(_ server: Server, registering types: [any Codable.Type] = [Draft.self]) -> Device {
        Device(server, registering: types, url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".records"))
    }

    /// This device after the app quits and launches again, perhaps as a newer version that
    /// registers `types`: the same file, holding the sync state the engine saved.
    func relaunched(registering types: [any Codable.Type] = [Draft.self]) -> Device {
        let device = Device(server, registering: types, url: url)
        device.known = known
        return device
    }

    /// Fetches every change since the last fetch, as `fetchedRecordZoneChanges` delivers them.
    func fetch() throws {
        let changed = server.records.filter { $0.value.version > cursor }
        try container.save(their: changed.values.map { $0.record.copy() as! CKRecord })
        for (id, entry) in changed { known[id] = entry.version }
        try container.save(deleted: server.tombstones.filter { $0.value > cursor }.map { $0.key })
        cursor = server.clock
    }

    /// Sends every pending change, as `nextRecordZoneChangeBatch` and `sentRecordZoneChanges` do.
    func send() throws {
        let pending = try container.pendingChanges()
        for recordID in pending.saves {
            let id = RecordContainer.RowID(name: recordID.recordName, zone: Zone(recordID.zoneID.zoneName, owner: recordID.zoneID.ownerName))
            let isNew = try container.row(id: id)?.metadata == nil
            guard let record = try container.send(id: id) else { continue }
            lastSent[recordID] = record
            try upload(record, isNew: isNew)
        }
        for recordID in pending.deletes {
            let id = RecordContainer.RowID(name: recordID.recordName, zone: Zone(recordID.zoneID.zoneName, owner: recordID.zoneID.ownerName))
            guard let deleted = try container.send(deleted: id) else { continue }
            if server.records[deleted] == nil {
                try container.save(failed: deleted, error: CKError(.unknownItem))
            } else {
                server.delete(deleted)
                try container.save(deleted: [deleted])
            }
        }
    }

    /// Uploads `record`, answering as the server would.
    func upload(_ record: CKRecord, isNew: Bool) throws {
        let current = server.records[record.recordID]
        if let current, isNew || current.version != known[record.recordID] {
            known[record.recordID] = current.version
            let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: current.record.copy()])
            try container.save(failed: record, error: error)
        } else if current == nil, !isNew {
            try container.save(failed: record, error: CKError(.unknownItem))
        } else {
            let saved = try server.save(record)
            known[record.recordID] = server.clock
            try container.save(sent: [saved])
        }
    }

    /// Sends and fetches until nothing is left to send, as the engine does over time.
    func sync() throws {
        for _ in 0..<4 {
            try send()
            try fetch()
            if try container.pendingRows().isEmpty { return }
        }
    }

    /// The record's newest value on this device.
    func value(id: UUID) throws -> Draft? {
        try value(Draft.self, id: id)
    }

    /// The record's newest value on this device, read as `type`.
    func value<T: Decodable>(_ type: T.Type, id: String) throws -> T? {
        guard let row = try container.row(id: id), !row.isDeleted, let json = row.ours ?? row.base else { return nil }
        return try json.decode(type)
    }

    func value<T: Decodable>(_ type: T.Type, id: UUID) throws -> T? {
        try value(type, id: id.uuidString)
    }

    func save<T: Encodable & Identifiable>(_ record: T, zone: Zone = "Drafts") throws where T.ID: Encodable {
        try container.save(our: record, zone: zone)
    }

    /// The files in the row's asset folder.
    func assetFiles(id: UUID) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: container.assetFolder(id: id), includingPropertiesForKeys: nil)) ?? []
    }
}

@Suite struct CloudKitSyncScenarioTests {
    private let id = UUID()
    private let folder = UUID()

    @Test func aRecordMadeOnOneDeviceArrivesWhole() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        let draft = Draft(id: id, title: "Hello", tags: ["a", "b"], attachment: Data([1, 2, 3]), folder: folder)
        try mine.save(draft)
        try mine.sync()
        try yours.fetch()

        let arrived = try #require(try yours.value(id: id))
        let saved = try #require(try mine.value(id: id))
        #expect(arrived.withoutFile == saved.withoutFile, "Each side holds the draft placed in its zone.")
        #expect(arrived.folder == draft.folder)
        #expect(arrived.$folder.zone == "Drafts")
        #expect(arrived.attachment == Data([1, 2, 3]))
        #expect(try mine.container.row(id: id)?.status == .synced)
        #expect(try yours.container.row(id: id)?.status == .synced)
    }

    @Test func anEditUploadsOnlyItsFieldAndIsConfirmed() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id, attachment: Data([1])))
        try mine.sync()
        try yours.fetch()

        // The same bytes from a new `Data` are the same asset, so the file is not sent again.
        try mine.save(Draft(id: id, title: "Edited", attachment: Data([1])))
        try mine.send()
        let sent = try #require(mine.lastSent[CKRecord.ID(recordName: id.uuidString, zoneID: Zone("Drafts").zoneID)])
        #expect(Set(sent.changedKeys()) == ["title"])

        let row = try #require(try mine.container.row(id: id))
        #expect(row.status == .synced, "\(row)")
        #expect(row.sent == nil)
        try yours.fetch()
        #expect(try yours.value(id: id)?.title == "Edited")
        #expect(try yours.value(id: id)?.attachment == Data([1]))
    }

    @Test func editsToDifferentFieldsOnTwoDevicesConverge() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id))
        try mine.sync()
        try yours.fetch()

        try mine.save(Draft(id: id, title: "Mine", views: Views(rawValue: 1)))
        try yours.save(Draft(id: id, body: "Yours", tags: ["a", "c"], views: Views(rawValue: 2)))
        try mine.sync()
        try yours.sync()
        try mine.fetch()

        let expected = Draft(id: id, title: "Mine", body: "Yours", tags: ["a", "c"], views: Views(rawValue: 3))
        #expect(try mine.value(id: id) == expected)
        #expect(try yours.value(id: id) == expected)
        #expect(try server.value(Draft.self, id: id) == expected)
        #expect(try yours.container.row(id: id)?.status == .synced)
    }

    @Test func editsToTheSameFieldConvergeOnTheLastDeviceToMerge() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id))
        try mine.sync()
        try yours.fetch()

        try mine.save(Draft(id: id, title: "Mine"))
        try yours.save(Draft(id: id, title: "Yours"))
        try mine.sync()
        try yours.sync()
        try mine.fetch()

        #expect(try mine.value(id: id)?.title == "Yours")
        #expect(try yours.value(id: id)?.title == "Yours")
    }

    @Test func clearedOptionalsReachTheOtherDevice() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id))
        try mine.sync()
        try yours.fetch()

        try mine.save(Draft(id: id, subtitle: nil, pin: nil))
        try mine.sync()
        try yours.fetch()

        let arrived = try #require(try yours.value(id: id))
        #expect(arrived.subtitle == nil)
        #expect(arrived.pin == nil)
        #expect(arrived.secret == "secret")
    }

    @Test func encryptedValuesTravelEncrypted() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id, secret: "hidden"))
        try mine.send()

        let stored = try #require(server.records.values.first?.record)
        #expect(stored.encryptedValues["secret"] as? String == "hidden")
        #expect(stored.encryptedValues["pin"] as? Int == 1234)
        #expect(stored["title"] as? String == "Untitled")
    }

    @Test func aDeleteReachesTheOtherDevice() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id, attachment: Data([1])))
        try mine.sync()
        try yours.fetch()

        try mine.container.delete(id: id)
        try mine.sync()
        try yours.fetch()
        #expect(try mine.container.row(id: id) == nil)
        #expect(try yours.container.row(id: id) == nil)
        #expect(yours.assetFiles(id: id).isEmpty)
    }

    @Test func anEditOutlivesADeleteFromAnotherDevice() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id))
        try mine.sync()
        try yours.fetch()

        try mine.container.delete(id: id)
        try mine.sync()
        try yours.save(Draft(id: id, title: "Still wanted"))
        try yours.sync()
        try mine.fetch()

        #expect(try mine.value(id: id)?.title == "Still wanted")
        #expect(try server.value(Draft.self, id: id)?.body == "", "The record is created again with every field.")
    }

    @Test func anEditDuringAnUploadIsSentNext() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id))
        try mine.sync()

        try mine.save(Draft(id: id, title: "First"))
        let inFlight = try #require(try mine.container.send(id: id))
        try mine.save(Draft(id: id, title: "First", body: "Typed while sending"))
        try mine.upload(inFlight, isNew: false)
        #expect(try mine.container.row(id: id)?.status == .waitingToUpload)

        try mine.sync()
        try yours.fetch()
        #expect(try yours.value(id: id) == Draft(id: id, title: "First", body: "Typed while sending"))
        #expect(try mine.container.row(id: id)?.status == .synced)
    }

    @Test func aChangeRevertedDuringAnUploadIsSentBack() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id))
        try mine.sync()

        try mine.save(Draft(id: id, title: "Briefly"))
        let inFlight = try #require(try mine.container.send(id: id))
        try mine.save(Draft(id: id))
        try mine.upload(inFlight, isNew: false)
        try mine.sync()
        #expect(try server.value(Draft.self, id: id)?.title == "Untitled")
    }

    @Test func aRecordTheServerLostIsCreatedAgainWhole() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id, body: "Body"))
        try mine.sync()
        server.lose(zone: Zone("Drafts").zoneID)

        try mine.save(Draft(id: id, title: "Edited", body: "Body"))
        try mine.sync()
        #expect(try server.value(Draft.self, id: id) == Draft(id: id, title: "Edited", body: "Body"))
    }

    @Test func aRejectedUploadWaitsUntilSavedAgain() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id))
        let record = try #require(try mine.container.send(id: id))
        try mine.container.save(failed: record, error: CKError(.quotaExceeded))
        #expect(try mine.container.pendingChanges().saves.isEmpty)

        try mine.save(Draft(id: id, title: "Again"))
        try mine.sync()
        #expect(try server.value(Draft.self, id: id)?.title == "Again")
    }

    @Test func manyRecordsSyncInOneBatch() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        let ids = (0..<50).map { _ in UUID() }
        for (index, id) in ids.enumerated() { try mine.save(Draft(id: id, title: "\(index)")) }
        try mine.sync()
        try yours.fetch()
        for (index, id) in ids.enumerated() {
            #expect(try yours.value(id: id)?.title == "\(index)")
        }
    }

    @Test func anAccountChangeStartsOverFromTheServer() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id, title: "Kept on the server", attachment: Data([1])))
        try mine.sync()

        try mine.container.clear()
        mine.cursor = 0
        mine.known = [:]
        #expect(try mine.container.row(id: id) == nil)
        try mine.fetch()
        #expect(try mine.value(id: id)?.title == "Kept on the server")
        #expect(try mine.value(id: id)?.attachment == Data([1]))
    }
}

@Suite struct CloudKitAssetScenarioTests {
    private let id = UUID()

    @Test func aReplacedAssetReachesTheOtherDeviceAndOldFilesGo() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id, attachment: Data([1])))
        try mine.sync()
        try yours.fetch()

        try mine.save(Draft(id: id, attachment: Data([2])))
        try mine.sync()
        try yours.fetch()
        #expect(try yours.value(id: id)?.attachment == Data([2]))
        #expect(mine.assetFiles(id: id).count == 1)
        #expect(yours.assetFiles(id: id).count == 1)
    }

    @Test func aRemovedAssetIsClearedOnTheOtherDevice() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id, attachment: Data([1])))
        try mine.sync()
        try yours.fetch()

        try mine.save(Draft(id: id))
        try mine.sync()
        try yours.fetch()
        #expect(try yours.value(id: id)?.attachment == nil)
        #expect(yours.assetFiles(id: id).isEmpty)
    }

    @Test func drawingsOnTwoDevicesMerge() throws {
        let server = Server()
        let mine = Device(server, registering: [Sketch.self]), yours = Device(server, registering: [Sketch.self])
        try mine.save(Sketch(id: id, drawing: Drawing(rawValue: Data([1]))))
        try mine.sync()
        try yours.fetch()

        try mine.save(Sketch(id: id, drawing: Drawing(rawValue: Data([1, 2]))))
        try yours.save(Sketch(id: id, drawing: Drawing(rawValue: Data([1, 3]))))
        try mine.sync()
        try yours.sync()
        try mine.fetch()

        #expect(try mine.value(Sketch.self, id: id)?.drawing == Drawing(rawValue: Data([1, 3, 2])))
        #expect(try yours.value(Sketch.self, id: id)?.drawing == Drawing(rawValue: Data([1, 3, 2])))
    }
}

@Suite struct CloudKitSchemaScenarioTests {
    private let id = UUID()

    @Test func anOlderAppLeavesFieldsItDoesNotKnow() throws {
        let server = Server()
        let newer = Device(server, registering: [Newer.Draft.self]), older = Device(server, registering: [Older.Draft.self])
        try newer.save(Newer.Draft(id: id, title: "New", color: "red"), zone: "Drafts")
        try newer.sync()
        try older.fetch()
        #expect(try older.value(Older.Draft.self, id: id)?.title == "New")

        try older.save(Older.Draft(id: id, title: "Edited on the older app"), zone: "Drafts")
        try older.sync()
        try newer.fetch()
        let draft = try #require(try newer.value(Newer.Draft.self, id: id))
        #expect(draft.title == "Edited on the older app")
        #expect(draft.color == "red")
    }

    @Test func aRecordThisAppCannotReadIsSkippedAndDoesNotStopUploads() throws {
        let server = Server()
        let mine = Device(server), other = Device(server, registering: [Incompatible.Draft.self])
        try mine.save(Draft(id: id))
        try mine.sync()

        // Another app version saves a shape this one cannot read.
        try other.fetch()
        try other.save(Incompatible.Draft(id: id, title: 7), zone: "Drafts")
        try other.sync()

        try mine.save(Draft(id: id, body: "Mine"))
        try mine.sync()
        let row = try #require(try mine.container.row(id: id))
        #expect(row.status == .synced, "\(row)")

        let stranger = UUID()
        try other.save(Incompatible.Draft(id: stranger, title: 1), zone: "Drafts")
        try other.sync()
        try mine.fetch()
        #expect(try mine.container.row(id: stranger) == nil)
    }
}

@Suite struct CloudKitZoneScenarioTests {
    private let id = UUID()

    @Test func anEncryptedDataResetSendsEverythingAgain() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id, title: "Kept", attachment: Data([1])))
        try mine.sync()
        server.lose(zone: Zone("Drafts").zoneID)

        try mine.container.save(deleted: Zone("Drafts").zoneID, reason: .encryptedDataReset)
        mine.known = [:]
        try mine.sync()
        #expect(try server.value(Draft.self, id: id)?.withoutFile == Draft(id: id, title: "Kept"))
        #expect(try mine.container.row(id: id)?.status == .synced)
    }

    @Test func aDeletedZoneIsCleared() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id, attachment: Data([1])))
        try mine.sync()
        try mine.container.save(deleted: Zone("Drafts").zoneID, reason: .deleted)
        #expect(try mine.container.row(id: id) == nil)
        #expect(mine.assetFiles(id: id).isEmpty)
    }

    @Test func thePublicDatabaseWorksWithoutAnEngine() throws {
        #expect(Zone.public.zoneID == CKRecordZone.default().zoneID)
        let server = Server()
        let mine = Device(server, registering: [Post.self]), yours = Device(server, registering: [Post.self])

        // Saved, sent and confirmed directly, then queried by the other device.
        try mine.save(Post(id: id, text: "Hello"), zone: .public)
        let record = try #require(try mine.container.send(id: id))
        #expect(record.recordID.zoneID == CKRecordZone.default().zoneID)
        try mine.upload(record, isNew: true)
        try yours.fetch()
        #expect(try yours.value(Post.self, id: id) == Post(id: id, text: "Hello"))

        // Both like it at once: the second upload is refused, merges, and goes again.
        try mine.save(Post(id: id, text: "Hello", likes: Views(rawValue: 1)), zone: .public)
        try yours.save(Post(id: id, text: "Hello", likes: Views(rawValue: 1)), zone: .public)
        try mine.sync()
        try yours.sync()
        #expect(try server.value(Post.self, id: id, zone: .public)?.likes == Views(rawValue: 2))
    }
}

@Suite struct CloudKitInstallScenarioTests {
    private let id = UUID()

    @Test func aFreshInstallReceivesEverythingAndSendsNothingBack() throws {
        let server = Server()
        let mine = Device(server)
        let ids = (0..<50).map { _ in UUID() }
        for (index, id) in ids.enumerated() { try mine.save(Draft(id: id, title: "\(index)")) }
        try mine.sync()

        let fresh = Device(server)
        try fresh.fetch()
        for (index, id) in ids.enumerated() {
            #expect(try fresh.value(id: id)?.title == "\(index)")
            #expect(try fresh.container.row(id: id)?.status == .synced)
        }
        #expect(try fresh.container.pendingChanges().saves.isEmpty)

        let clock = server.clock
        try fresh.sync()
        #expect(server.clock == clock, "A fresh install uploads nothing it only received.")
    }

    @Test func aReinstallStartsFromTheServerWithoutTheUnsentEdit() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id, title: "Synced"))
        try mine.sync()
        try mine.save(Draft(id: id, title: "Never sent"))

        // The app is deleted with its database and sync state, then installed again.
        let reinstalled = Device(server)
        try reinstalled.sync()
        #expect(try reinstalled.value(id: id)?.title == "Synced")
        #expect(try reinstalled.container.row(id: id)?.status == .synced)
        #expect(try server.value(Draft.self, id: id)?.title == "Synced")
    }

    @Test func aRecordSentBeforeTheAppQuitIsNotDuplicated() throws {
        let server = Server()
        let mine = Device.onDisk(server)
        try mine.save(Draft(id: id, title: "New"))

        // The server saves the new record, but the app quits before hearing back.
        let record = try #require(try mine.container.send(id: id))
        _ = try server.save(record)

        let relaunched = mine.relaunched()
        #expect(try relaunched.container.pendingChanges().saves.count == 1, "The record still waits to upload.")
        try relaunched.sync()
        #expect(server.records.count == 1)
        #expect(try server.value(Draft.self, id: id)?.title == "New")
        #expect(try relaunched.container.row(id: id)?.status == .synced)
        #expect(try relaunched.container.pendingChanges().saves.isEmpty)
    }

    @Test func anAppUpdateReadsOldRowsAndSyncsItsNewField() throws {
        let server = Server()
        let mine = Device.onDisk(server, registering: [Older.Draft.self])
        let yours = Device.onDisk(server, registering: [Older.Draft.self])
        try mine.save(Older.Draft(id: id, title: "Old"), zone: "Drafts")
        try mine.sync()
        try yours.fetch()

        // Both devices update to a version that adds an optional color.
        let mineUpdated = mine.relaunched(registering: [Newer.Draft.self])
        let yoursUpdated = yours.relaunched(registering: [Newer.Draft.self])
        let old = try #require(try mineUpdated.value(Newer.Draft.self, id: id))
        #expect(old.title == "Old")
        #expect(old.color == nil)

        try mineUpdated.save(Newer.Draft(id: id, title: "Old", color: "blue"), zone: "Drafts")
        try mineUpdated.sync()
        try yoursUpdated.fetch()
        #expect(try yoursUpdated.value(Newer.Draft.self, id: id)?.color == "blue")
        #expect(try yoursUpdated.value(Newer.Draft.self, id: id)?.title == "Old")
    }

    @Test func aDeviceThatUpdatesLaterFetchesTheFieldItMissed() throws {
        let server = Server()
        let mine = Device.onDisk(server, registering: [Newer.Draft.self])
        let yours = Device.onDisk(server, registering: [Older.Draft.self])
        try mine.save(Newer.Draft(id: id, title: "New", color: "blue"), zone: "Drafts")
        try mine.sync()
        try yours.fetch()
        #expect(try yours.value(Newer.Draft.self, id: id)?.color == nil, "The older app cannot keep a field it does not have.")

        let yoursUpdated = yours.relaunched(registering: [Newer.Draft.self])
        #expect(yoursUpdated.cursor == 0, "A changed schema starts the engine over.")
        try yoursUpdated.fetch()
        #expect(try yoursUpdated.value(Newer.Draft.self, id: id)?.color == "blue")
        #expect(try yoursUpdated.container.pendingRows().isEmpty)
    }

    @Test func aDeviceThatUpdatesLaterFetchesARecordTypeItDidNotHave() throws {
        let server = Server()
        let mine = Device.onDisk(server, registering: [Draft.self, Page.self])
        let yours = Device.onDisk(server, registering: [Draft.self])
        try mine.save(Draft(id: id, title: "Kept"))
        try mine.save(Page(id: "intro", title: "Welcome"))
        try mine.sync()
        try yours.save(Draft(id: UUID(), title: "Unsent"))
        try yours.fetch()
        let page = try RecordContainer.recordName(for: "intro", type: "Page")
        #expect(try yours.container.row(id: page) == nil, "The older app skips a type it does not have.")

        let yoursUpdated = yours.relaunched(registering: [Draft.self, Page.self])
        try yoursUpdated.fetch()
        let arrived = try yoursUpdated.value(Page.self, id: page)
        #expect(arrived == Page(id: "intro", title: "Welcome"))
        let waiting = try yoursUpdated.container.pendingChanges().saves
        #expect(waiting.count == 1, "The unsent edit still waits after the engine starts over.")
    }
}

@Suite struct CloudKitDevicesScenarioTests {
    private let id = UUID()

    @Test func threeDevicesConvergeInEveryOrder() throws {
        let expected = Draft(id: id, title: "A", body: "B", tags: ["a", "c"], views: Views(rawValue: 7))
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let server = Server()
            let devices = [Device(server), Device(server), Device(server)]
            try devices[0].save(Draft(id: id))
            try devices[0].sync()
            for device in devices { try device.fetch() }

            try devices[0].save(Draft(id: id, title: "A", views: Views(rawValue: 1)))
            try devices[1].save(Draft(id: id, body: "B", views: Views(rawValue: 2)))
            try devices[2].save(Draft(id: id, tags: ["a", "c"], views: Views(rawValue: 4)))
            for index in order { try devices[index].sync() }
            for device in devices { try device.sync() }

            for device in devices { #expect(try device.value(id: id) == expected, "order \(order)") }
            #expect(try server.value(Draft.self, id: id) == expected, "order \(order)")
        }
    }

    @Test func aDeviceOfflineAcrossLaunchesLosesNothing() throws {
        let server = Server()
        var mine = Device.onDisk(server)
        let yours = Device(server)
        try mine.save(Draft(id: id))
        try mine.sync()
        try yours.fetch()

        // Offline: an edit, a quit, another edit and a new record, another quit.
        try mine.save(Draft(id: id, title: "Offline"))
        mine = mine.relaunched()
        try mine.save(Draft(id: id, title: "Offline", body: "Still offline"))
        let created = UUID()
        try mine.save(Draft(id: created, title: "Made offline"))
        mine = mine.relaunched()

        // Meanwhile the other device changes the same record.
        try yours.save(Draft(id: id, tags: ["a", "b"], views: Views(rawValue: 5)))
        try yours.sync()

        try mine.sync()
        try yours.fetch()
        let expected = Draft(id: id, title: "Offline", body: "Still offline", tags: ["a", "b"], views: Views(rawValue: 5))
        #expect(try mine.value(id: id) == expected)
        #expect(try yours.value(id: id) == expected)
        #expect(try yours.value(id: created)?.title == "Made offline")
        #expect(try mine.container.pendingChanges().saves.isEmpty)
    }

    @Test func aRecordCreatedOnTwoDevicesBecomesOne() throws {
        let server = Server()
        let mine = Device(server, registering: [Page.self]), yours = Device(server, registering: [Page.self])
        try mine.save(Page(id: "intro", title: "Mine"), zone: "Drafts")
        try yours.save(Page(id: "intro", body: "Yours"), zone: "Drafts")
        try mine.sync()
        try yours.sync()
        try mine.sync()

        let id = try RecordContainer.recordName(for: "intro", type: "Page")
        #expect(server.records.count == 1)
        let stored = try #require(try server.value(Page.self, id: id))
        #expect(try mine.value(Page.self, id: id) == stored)
        #expect(try yours.value(Page.self, id: id) == stored)
        #expect(try mine.container.pendingChanges().saves.isEmpty)
        #expect(try yours.container.pendingChanges().saves.isEmpty)
    }
}

@Suite struct CloudKitTwoZoneScenarioTests {
    private let id = UUID()

    @Test func theSameRecordInTwoZonesSyncsAsTwoRecords() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        try mine.save(Draft(id: id, title: "Kept"), zone: "Drafts")
        try mine.save(Draft(id: id, title: "Archived"), zone: "Archive")
        try mine.sync()
        #expect(try server.value(Draft.self, id: id, zone: "Drafts")?.title == "Kept")
        #expect(try server.value(Draft.self, id: id, zone: "Archive")?.title == "Archived")

        try yours.fetch()
        let drafts = RecordContainer.RowID(name: id, zone: "Drafts"), archive = RecordContainer.RowID(name: id, zone: "Archive")
        #expect(try yours.container.row(id: drafts)?.base?["title"] == "Kept")
        #expect(try yours.container.row(id: archive)?.base?["title"] == "Archived")

        try yours.container.delete(id: archive)
        try yours.sync()
        try mine.fetch()
        #expect(try server.value(Draft.self, id: id, zone: "Archive") == nil)
        #expect(try mine.container.row(id: archive) == nil)
        #expect(try mine.container.row(id: drafts)?.base?["title"] == "Kept", "Deleting one copy leaves the other.")
    }
}

@Suite struct CloudKitDeliveryScenarioTests {
    private let id = UUID()

    /// The sync engine delivers each record's current version in order, so the container
    /// relies on that order and only has to shrug off a version delivered again.
    @Test func aChangeDeliveredTwiceChangesNothing() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: Zone("Drafts").zoneID)
        try mine.save(Draft(id: id, title: "First"))
        try mine.sync()
        try mine.save(Draft(id: id, title: "Second"))
        try mine.sync()
        let second = try #require(server.records[recordID]?.record.copy() as? CKRecord)

        try yours.container.save(their: [second])
        try yours.container.save(their: [second])
        #expect(try yours.value(id: id)?.title == "Second")
        #expect(try yours.container.pendingChanges().saves.isEmpty)
    }

    @Test func failuresWorthRetryingKeepTheChangeUntilItIsConfirmedOnce() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id, title: "Patient"))
        for code: CKError.Code in [.networkUnavailable, .networkFailure, .zoneBusy, .requestRateLimited, .serviceUnavailable] {
            let record = try #require(try mine.container.send(id: id), "\(code)")
            try mine.container.save(failed: record, error: CKError(code))
            #expect(try mine.container.row(id: id)?.status == .waitingToUpload, "\(code)")
            #expect(try mine.container.pendingChanges().saves.count == 1, "\(code)")
        }
        try mine.sync()
        #expect(server.clock == 1, "The record is saved on the server exactly once.")
        #expect(try server.value(Draft.self, id: id)?.title == "Patient")
        #expect(try mine.container.row(id: id)?.status == .synced)

        try mine.container.delete(id: id)
        let recordID = try #require(try mine.container.send(deleted: id))
        try mine.container.save(failed: recordID, error: CKError(.networkUnavailable))
        #expect(try mine.container.pendingChanges().deletes == [recordID])
        try mine.sync()
        #expect(server.records.isEmpty)
        #expect(try mine.container.row(id: id) == nil)
    }
}

@Suite struct CloudKitRandomScenarioTests {
    @Test(arguments: [1, 2, 3] as [UInt64])
    func randomActivityConverges(seed: UInt64) throws {
        var random = SeededGenerator(state: seed)
        let server = Server()
        let devices = [Device(server), Device(server), Device(server)]
        let ids = (0..<5).map { _ in UUID() }

        for _ in 0..<200 {
            let device = devices.randomElement(using: &random)!
            let id = ids.randomElement(using: &random)!
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<5:
                var draft = try device.value(id: id) ?? Draft(id: id)
                switch Int.random(in: 0..<3, using: &random) {
                case 0: draft.title = ["One", "Two", "Three"].randomElement(using: &random)!
                case 1: draft.views.rawValue += 1
                default: draft.tags.append(["x", "y", "z"].randomElement(using: &random)!)
                }
                try device.save(draft)
            case 5:
                if try device.container.row(id: id) != nil { try device.container.delete(id: id) }
            case 6: try device.send()
            case 7: try device.fetch()
            default: try device.sync()
            }
        }

        for _ in 0..<2 {
            for device in devices { try device.sync() }
        }
        for device in devices { try device.fetch() }
        for id in ids {
            let stored = try server.value(Draft.self, id: id)
            for (index, device) in devices.enumerated() {
                #expect(try device.value(id: id) == stored, "seed \(seed), device \(index), record \(id)")
                #expect(try device.container.pendingRows().isEmpty, "seed \(seed), device \(index)")
            }
        }
    }
}

#endif
