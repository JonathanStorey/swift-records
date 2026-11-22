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
    @Reference var folder: RecordID<Folder>? = nil

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

private enum Incompatible {
    struct Draft: Codable, Identifiable, Mergeable {
        var id: UUID
        var title: Int
    }
}

/// The server: each record with the version it was last saved at, and a tombstone for
/// each deleted one.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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
    func value<T: Decodable>(_ type: T.Type, id: UUID, zone: Zone = "Drafts") throws -> T? {
        guard let record = records[CKRecord.ID(recordName: id.uuidString, zoneID: zone.zoneID)]?.record else { return nil }
        return try CKRecordDecoder().decode(type, from: record)
    }
}

/// A device: its container, and what it last heard from the server.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private final class Device {
    let container: RecordContainer
    let server: Server
    /// The server version of each record this device last fetched or saved.
    var known: [CKRecord.ID: Int] = [:]
    var cursor = 0
    /// What the last upload sent, by record.
    var lastSent: [CKRecord.ID: CKRecord] = [:]

    init(_ server: Server, registering types: [any (Codable & Mergeable).Type] = [Draft.self]) {
        self.server = server
        container = RecordContainer.inMemory(types)
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
            let id = UUID(uuidString: recordID.recordName)!
            let isNew = try container.row(id: id)?.metadata == nil
            guard let record = try container.send(id: id) else { continue }
            lastSent[recordID] = record
            try upload(record, isNew: isNew)
        }
        for recordID in pending.deletes {
            guard let deleted = try container.send(deleted: UUID(uuidString: recordID.recordName)!) else { continue }
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
    func value<T: Decodable>(_ type: T.Type, id: UUID) throws -> T? {
        guard let row = try container.row(id: id), !row.isDeleted, let json = row.ours ?? row.base else { return nil }
        return try json.decode(type)
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
    private let folder = RecordID<Folder>(name: UUID(), zone: "Drafts")

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aRecordMadeOnOneDeviceArrivesWhole() throws {
        let server = Server()
        let mine = Device(server), yours = Device(server)
        let draft = Draft(id: id, title: "Hello", tags: ["a", "b"], attachment: Data([1, 2, 3]), folder: folder)
        try mine.save(draft)
        try mine.sync()
        try yours.fetch()

        let arrived = try #require(try yours.value(id: id))
        #expect(arrived.withoutFile == draft.withoutFile)
        #expect(arrived.attachment == Data([1, 2, 3]))
        #expect(try mine.container.row(id: id)?.status == .synced)
        #expect(try yours.container.row(id: id)?.status == .synced)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
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

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    @Test func aDeletedZoneIsCleared() throws {
        let server = Server()
        let mine = Device(server)
        try mine.save(Draft(id: id, attachment: Data([1])))
        try mine.sync()
        try mine.container.save(deleted: Zone("Drafts").zoneID, reason: .deleted)
        #expect(try mine.container.row(id: id) == nil)
        #expect(mine.assetFiles(id: id).isEmpty)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
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

#endif
