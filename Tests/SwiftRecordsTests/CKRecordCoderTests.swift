#if canImport(CloudKit)
import CloudKit
import CoreLocation
import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Folder: Identifiable {
    var id: UUID
}

private enum Mood: String, Codable {
    case calm, busy
}

private struct Size: Codable, Equatable {
    var width: Double
    var height: Double
}

private struct Sample: Codable, Identifiable {
    var id: UUID
    var title: String
    var count: Int
    var isPinned: Bool
    var score: Double
    var created: Date
    var bytes: Data
    var link: URL
    var mood: Mood
    var words: [String]
    var tags: Set<String>
    var size: Size
    var subtitle: String?
    @Encrypted var secret: String = ""
    var home: Location
    @Asset var file: Data? = nil
    @Reference var folder: RecordID<Folder>? = nil
    @References var related: [RecordID<Folder>] = []
    @Timestamp var updated: Date? = nil
}

private struct Linked: Decodable {
    var folder: RecordReference
}

private struct Count: Decodable {
    var count: Int
}

private struct Shapes: Codable, Equatable {
    var id: UUID
    var sizes: [Size]
    var counts: [String: Int]
    var maybe: [String?]
    var grid: [[Int]]
    @Encrypted var pin: Int? = nil
    var none: String?
}

private struct Parented: Codable {
    var id: UUID
    @Reference(isParent: true) var folder: RecordID<Folder>? = nil
}

private struct Note: Codable, Identifiable, Mergeable {
    var id: UUID
    var title: String
}

private struct Page: Codable, Mergeable {
    var slug: String
    var title: String
}

private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
private let folderID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

private let zoneID = CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName)

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private func record(_ values: [String: CKRecordValue] = [:], type: String = "Sample", name: String = id.uuidString) -> CKRecord {
    let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    for (key, value) in values { record[key] = value }
    return record
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private func folderReference(_ action: CKRecord.ReferenceAction = .none) -> CKRecord.Reference {
    CKRecord.Reference(recordID: CKRecord.ID(recordName: folderID.uuidString, zoneID: zoneID), action: action)
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private func fullSample() throws -> CKRecord {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([9]).write(to: file)
    let sample = record([
        "id": id.uuidString as NSString,
        "title": "Hello" as NSString,
        "count": 3 as NSNumber,
        "isPinned": 1 as NSNumber,
        "score": 2.5 as NSNumber,
        "created": Date(timeIntervalSinceReferenceDate: 100) as NSDate,
        "bytes": Data([1, 2]) as NSData,
        "link": "https://example.com/a" as NSString,
        "mood": "busy" as NSString,
        "words": ["a", "b"] as NSArray,
        "tags": ["x"] as NSArray,
        "size": Data(#"{"width":1,"height":2}"#.utf8) as NSData,
        "home": CLLocation(latitude: 41.88, longitude: -87.63),
        "file": CKAsset(fileURL: file),
        "folder": folderReference(.deleteSelf),
        "related": [folderReference()] as NSArray,
    ])
    sample.encryptedValues["secret"] = "pin" as NSString
    return sample
}

@Suite struct CKRecordDecoderTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func decodesEachFieldType() throws {
        let sample = try fullSample()
        let decoded = try CKRecordDecoder().decode(Sample.self, from: sample)
        let home = try #require(sample.object(forKey: "home") as? CLLocation)

        #expect(decoded.id == id)
        #expect(decoded.title == "Hello")
        #expect(decoded.count == 3)
        #expect(decoded.isPinned)
        #expect(decoded.score == 2.5)
        #expect(decoded.created == Date(timeIntervalSinceReferenceDate: 100))
        #expect(decoded.bytes == Data([1, 2]))
        #expect(decoded.link == URL(string: "https://example.com/a"))
        #expect(decoded.mood == .busy)
        #expect(decoded.words == ["a", "b"])
        #expect(decoded.tags == ["x"])
        #expect(decoded.size == Size(width: 1, height: 2))
        #expect(decoded.subtitle == nil)
        #expect(decoded.secret == "pin")
        #expect(decoded.home == Location(home))
        #expect(decoded.$file == (sample.object(forKey: "file") as? CKAsset)?.fileURL)
        #expect(decoded.file == Data([9]))
        let folder = RecordID<Folder>(name: folderID, zone: "Notes")
        #expect(decoded.folder == folder)
        #expect(decoded.related == [folder])
        #expect(decoded.updated == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func readsTheActionAndMarksTheParent() throws {
        let linked = record(["folder": folderReference(.deleteSelf)])
        let plain = try CKRecordDecoder().decode(Linked.self, from: linked).folder
        #expect(!plain.isParent)
        #expect(plain.zone == "Notes")
        #expect(plain.owner == CKCurrentUserDefaultName)
        #expect(plain.action == .deleteSelf)
        linked["folder"] = folderReference()
        linked.parent = folderReference()
        #expect(try CKRecordDecoder().decode(Linked.self, from: linked).folder.isParent)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func throwsForAMissingField() {
        #expect(throws: DecodingError.self) { try CKRecordDecoder().decode(Count.self, from: record()) }
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func throwsForAValueOfAnotherType() {
        for value in ["three" as NSString, 1.5 as NSNumber] as [CKRecordValue] {
            #expect(throws: DecodingError.self) { try CKRecordDecoder().decode(Count.self, from: record(["count": value])) }
        }
    }
}

/// The JSON bytes the encoder stores for a nested value. Encoding these cannot fail.
private func json(_ value: some Encodable) -> Data {
    Data(try! JSONRepresentation(value).description.utf8)
}

@Suite struct CKRecordEncoderTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func roundTripsEachFieldTypeAndClearsTheRest() throws {
        let sample = try CKRecordDecoder().decode(Sample.self, from: fullSample())
        let encoded = record(["stale": "x" as NSString])
        encoded.encryptedValues["oldSecret"] = "y" as NSString

        try CKRecordEncoder().encode(sample, to: encoded)
        let decoded = try CKRecordDecoder().decode(Sample.self, from: encoded)

        #expect(try JSONRepresentation(decoded) == JSONRepresentation(sample))
        #expect(encoded.encryptedValues.allKeys() == ["secret"])
        #expect(!encoded.allKeys().contains("stale"))
        #expect(encoded.object(forKey: "id") as? String == id.uuidString)
        #expect(!encoded.allKeys().contains("subtitle"))
        #expect(!encoded.allKeys().contains("updated"))
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func storesNestedValuesAsJSON() throws {
        let shapes = Shapes(id: id, sizes: [Size(width: 1, height: 2)], counts: ["a": 1], maybe: ["b", nil], grid: [[1], [2, 3]], pin: 4)
        let encoded = record(type: "Shapes")
        try CKRecordEncoder().encode(shapes, to: encoded)

        #expect(encoded.object(forKey: "sizes") as? [Data] == [json(shapes.sizes[0])])
        #expect(encoded.object(forKey: "counts") as? Data == json(shapes.counts))
        #expect(encoded.object(forKey: "maybe") as? Data == json(shapes.maybe))
        #expect(encoded.object(forKey: "grid") as? Data == json(shapes.grid))
        #expect(encoded.encryptedValues["pin"] as? Int64 == 4)
        #expect(encoded.object(forKey: "pin") == nil)
        #expect(try CKRecordDecoder().decode(Shapes.self, from: encoded) == shapes)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func setsAndClearsTheParent() throws {
        let source = record(["id": id.uuidString as NSString, "folder": folderReference()])
        source.parent = folderReference()
        let parented = try CKRecordDecoder().decode(Parented.self, from: source)

        let encoded = record()
        try CKRecordEncoder().encode(parented, to: encoded)
        #expect(encoded.parent?.recordID == folderReference().recordID)
        #expect((encoded.object(forKey: "folder") as? CKRecord.Reference)?.recordID == folderReference().recordID)

        try CKRecordEncoder().encode(Parented(id: id), to: encoded)
        #expect(encoded.parent == nil)
        #expect(encoded.object(forKey: "folder") == nil)
    }
}

@Suite struct RecordContainerCloudKitTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func savesARecordNamedByAHashOfItsID() throws {
        let page = Page(slug: "intro", title: "Hello")
        let container = RecordContainer.inMemory(Page.self)
        let name = try RecordContainer.recordID(for: page.slug, type: "Page")
        try container.save(their: record(["slug": "intro" as NSString, "title": "Hello" as NSString], type: "Page", name: name.uuidString))

        let row = try #require(try container.row(id: name))
        #expect(row.base == (try? JSONRepresentation(page)))
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func savesTheDecodedRecordAsBase() throws {
        let container = RecordContainer.inMemory(Note.self)
        try container.save(their: record(["id": id.uuidString as NSString, "title": "Hello" as NSString], type: "Note"))

        let row = try #require(try container.row(id: id))
        #expect(row.base == (try? JSONRepresentation(Note(id: id, title: "Hello"))))
        #expect(row.zone == "Notes")
        #expect(row.zone.owner == CKCurrentUserDefaultName)
        #expect(row.type == "Note")
        #expect(row.metadata != nil)
        #expect(row.status == .synced, "\(row)")
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func skipsARecordNotNamedByAUUID() throws {
        let container = RecordContainer.inMemory(Note.self)
        try container.save(their: record(["title": "Hello" as NSString], type: "Note", name: "not-a-uuid"))
        #expect(try container.row(id: id) == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func skipsANewRecordItCannotRead() throws {
        for (registered, type) in [(true, "Note"), (false, "Other")] {
            let container = registered ? RecordContainer.inMemory(Note.self) : RecordContainer()
            try container.save(their: record(["title": "Hello" as NSString], type: type))
            #expect(try container.row(id: id) == nil)
        }
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aVersionItCannotReadKeepsTheRowsContent() throws {
        let container = RecordContainer.inMemory(Note.self)
        try container.save(their: record(["id": id.uuidString as NSString, "title": "Hello" as NSString], type: "Note"))
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        try container.save(their: record(["title": "Newer" as NSString], type: "Note"))

        let row = try #require(try container.row(id: id))
        #expect(row.base == (try? JSONRepresentation(Note(id: id, title: "Hello"))))
        #expect(row.ours == (try? JSONRepresentation(Note(id: id, title: "Ours"))))
        #expect(row.metadata != nil)
        #expect(row.status == .waitingToUpload, "\(row)")
    }
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private func noteRecord(_ title: String) -> CKRecord {
    record(["id": id.uuidString as NSString, "title": title as NSString], type: "Note")
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private func noteContainer() -> RecordContainer {
    let container = RecordContainer.inMemory(Note.self)
    return container
}

@Suite struct RecordContainerUploadTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func sendsNothingWithoutLocalChanges() throws {
        let container = noteContainer()
        #expect(try container.send(id: id) == nil)
        try container.save(their: noteRecord("Hello"))
        #expect(try container.send(id: id) == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func sendsANewRecordInItsZone() throws {
        let container = noteContainer()
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")

        let sent = try #require(try container.send(id: id))
        #expect(sent.recordID == CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
        #expect(sent.recordType == "Note")
        #expect(sent["title"] as? String == "Draft")
        #expect(sent["id"] as? String == id.uuidString)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func sendsAnEditOnTheServersRecord() throws {
        let container = noteContainer()
        let server = noteRecord("Hello")
        try container.save(their: server)
        try container.save(our: Note(id: id, title: "Edited"), zone: "Notes")

        let sent = try #require(try container.send(id: id))
        #expect(sent.recordID == server.recordID)
        #expect(sent["title"] as? String == "Edited")
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aSavedUploadIsSynced() throws {
        let container = noteContainer()
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")
        try container.save(sent: try #require(try container.send(id: id)))

        let row = try #require(try container.row(id: id))
        #expect(row.status == .synced, "\(row)")
        #expect(row.base == (try? JSONRepresentation(Note(id: id, title: "Draft"))))
        #expect(row.metadata != nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func anEditDuringTheUploadStaysWaiting() throws {
        let container = noteContainer()
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")
        let sent = try #require(try container.send(id: id))
        try container.save(our: Note(id: id, title: "Draft, longer"), zone: "Notes")
        try container.save(sent: sent)

        #expect(try container.row(id: id)?.status == .waitingToUpload)
        #expect(try container.send(id: id)?["title"] as? String == "Draft, longer")
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aRejectedUploadKeepsItsErrorUntilSavedAgain() throws {
        let container = noteContainer()
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")
        let error = CKError(.quotaExceeded)
        try container.save(failed: try #require(try container.send(id: id)), error: error)

        #expect(try container.row(id: id)?.status == .rejected(error.localizedDescription))
        #expect(try container.send(id: id) == nil)
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")
        #expect(try container.send(id: id) != nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aRecordThatCannotBeEncodedIsMarked() throws {
        let container = RecordContainer()
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")
        #expect(try container.send(id: id) == nil)
        #expect(try container.row(id: id)?.error?.contains("could not send") == true)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aFailureWorthRetryingChangesNothing() throws {
        let container = noteContainer()
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")
        let sent = try #require(try container.send(id: id))
        let before = try container.row(id: id)
        try container.save(failed: sent, error: CKError(.networkFailure))
        #expect(try container.row(id: id) == before)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aRecordTheServerLostIsCreatedAgain() throws {
        let container = noteContainer()
        try container.save(their: noteRecord("Hello"))
        try container.save(our: Note(id: id, title: "Edited"), zone: "Notes")
        try container.save(failed: try #require(try container.send(id: id)), error: CKError(.unknownItem))

        let row = try #require(try container.row(id: id))
        #expect(row.metadata == nil)
        #expect(row.base == nil, "The next send creates the record with every field.")
        #expect(row.status == .waitingToUpload)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aNewerServerVersionMergesIn() throws {
        let container = noteContainer()
        try container.save(their: noteRecord("Hello"))
        try container.save(our: Note(id: id, title: "Ours"), zone: "Notes")
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: noteRecord("Theirs")])
        try container.save(failed: try #require(try container.send(id: id)), error: error)

        let row = try #require(try container.row(id: id))
        #expect(row.base == (try? JSONRepresentation(Note(id: id, title: "Theirs"))))
        #expect(row.ours == (try? JSONRepresentation(Note(id: id, title: "Ours"))), "Ours wins the conflicting title by default.")
        #expect(row.status == .waitingToUpload)
    }
}

@Suite struct RecordContainerDeleteUploadTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func sendsADeleteOnlyWhenOneIsWaiting() throws {
        let container = noteContainer()
        try container.save(their: noteRecord("Hello"))
        #expect(try container.send(deleted: id) == nil)

        try container.delete(id: id)
        #expect(try container.send(deleted: id) == CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
        #expect(try container.send(id: id) == nil)
    }

    @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
    @Test func aZoneDeletedByAnEncryptedDataResetIsSentAgain() throws {
        let container = noteContainer()
        try container.save(their: noteRecord("Hello"))
        try container.save(deleted: zoneID, reason: .encryptedDataReset)
        #expect(try container.pendingChanges().saves == [CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)])

        try container.save(deleted: zoneID, reason: .deleted)
        #expect(try container.row(id: id) == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aConfirmedDeleteRemovesTheRow() throws {
        let container = noteContainer()
        try container.save(their: noteRecord("Hello"))
        try container.delete(id: id)
        try container.save(deleted: try #require(try container.send(deleted: id)))
        #expect(try container.row(id: id) == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aDeleteOfAMissingRecordCountsAsDone() throws {
        let container = noteContainer()
        try container.save(their: noteRecord("Hello"))
        try container.delete(id: id)
        try container.save(failed: try #require(try container.send(deleted: id)), error: CKError(.unknownItem))
        #expect(try container.row(id: id) == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aRejectedDeleteKeepsItsErrorAndARetryableOneChangesNothing() throws {
        let container = noteContainer()
        try container.save(their: noteRecord("Hello"))
        try container.delete(id: id)
        let recordID = try #require(try container.send(deleted: id))

        let before = try container.row(id: id)
        try container.save(failed: recordID, error: CKError(.networkFailure))
        #expect(try container.row(id: id) == before)

        let error = CKError(.permissionFailure)
        try container.save(failed: recordID, error: error)
        #expect(try container.row(id: id)?.status == .rejected(error.localizedDescription))
        #expect(try container.send(deleted: id) == nil)
    }
}

@Suite struct RecordContainerBatchCloudKitTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func savesManyRecordsAtOnce() throws {
        let container = noteContainer()
        let other = UUID()
        let second = record(["id": other.uuidString as NSString, "title": "Second" as NSString], type: "Note", name: other.uuidString)
        try container.save(their: [noteRecord("First"), second])
        #expect(try container.row(id: id)?.base?["title"] == "First")
        #expect(try container.row(id: other)?.base?["title"] == "Second")

        try container.save(deleted: [second.recordID])
        #expect(try container.row(id: other) == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func confirmsManyUploadsAtOnce() throws {
        let container = noteContainer()
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")
        try container.save(sent: [try #require(try container.send(id: id))])
        #expect(try container.row(id: id)?.status == .synced)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func listsPendingSavesAndDeletes() throws {
        let container = noteContainer()
        let other = UUID()
        try container.save(our: Note(id: id, title: "Draft"), zone: "Notes")
        try container.save(their: record(["id": other.uuidString as NSString, "title": "Old" as NSString], type: "Note", name: other.uuidString))
        try container.delete(our: Note(id: other, title: "Old"))

        let pending = try container.pendingChanges()
        #expect(pending.saves == [CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)])
        #expect(pending.deletes == [CKRecord.ID(recordName: other.uuidString, zoneID: zoneID)])
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func skipsAShare() throws {
        let container = noteContainer()
        let share = CKShare(rootRecord: noteRecord("Hello"))
        try container.save(their: share)
        let pending = try container.pendingChanges()
        #expect(pending.saves.isEmpty && pending.deletes.isEmpty)
        if let shareID = UUID(uuidString: share.recordID.recordName) {
            #expect(try container.row(id: shareID) == nil)
        }
    }
}

private struct Attachment: Codable, Mergeable {
    var id: UUID
    @Asset var file: Data? = nil
}

@Suite struct RecordContainerAssetCloudKitTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func keepsADownloadedAssetAfterTheEngineRemovesItsFile() throws {
        let container = RecordContainer.inMemory(Attachment.self)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([7]).write(to: file)
        try container.save(their: record(["id": id.uuidString as NSString, "file": CKAsset(fileURL: file)], type: "Attachment"))
        try FileManager.default.removeItem(at: file)

        guard case .string(let text)? = try container.row(id: id)?.base?["file"], let stored = URL(string: text) else {
            Issue.record("Expected a stored file")
            return
        }
        #expect(text.hasPrefix(container.assetFolder(id: id).absoluteString))
        #expect(try Data(contentsOf: stored) == Data([7]))
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func sendsTheStoredFile() throws {
        let container = RecordContainer.inMemory(Attachment.self)
        try container.save(our: Attachment(id: id, file: Data([8])), id: \.id, zone: "Notes")

        let sent = try #require(try container.send(id: id))
        let asset = try #require(sent["file"] as? CKAsset)
        #expect(asset.fileURL?.absoluteString.hasPrefix(container.assetFolder(id: id).absoluteString) == true)
    }
}
private struct Memo: Codable, Identifiable, Mergeable {
    var id: UUID
    var title: String
    var subtitle: String?
    @Encrypted var pin: Int? = nil
}

/// A record whose encrypted key differs from its property name.
private struct Locked: Codable, Identifiable, Mergeable {
    var id: UUID
    @Encrypted var pin: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case pin = "pin_code"
    }
}

@Suite struct RecordContainerChangedFieldTests {
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    private func synced() throws -> RecordContainer {
        let container = RecordContainer.inMemory(Memo.self)
        let server = record(["id": id.uuidString as NSString, "title": "Hello" as NSString, "subtitle": "Draft" as NSString], type: "Memo")
        server.encryptedValues["pin"] = 4 as NSNumber
        try container.save(their: server)
        return container
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func sendsOnlyTheChangedFields() throws {
        let container = try synced()
        try container.save(our: Memo(id: id, title: "Edited", subtitle: "Draft", pin: 4), zone: "Notes")

        let sent = try #require(try container.send(id: id))
        #expect(sent.changedKeys() == ["title"])
        #expect(sent["title"] as? String == "Edited")
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func clearsAnOptionalSetToNil() throws {
        let container = try synced()
        try container.save(our: Memo(id: id, title: "Hello", subtitle: nil, pin: nil), zone: "Notes")

        let sent = try #require(try container.send(id: id))
        #expect(Set(sent.changedKeys()) == ["subtitle", "pin"])
        #expect(sent["subtitle"] == nil)
        #expect(sent.encryptedValues["pin"] == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func clearsAnEncryptedValueUnderACustomKeyOnTheEncryptedSide() throws {
        let container = RecordContainer.inMemory(Locked.self)
        let server = record(["id": id.uuidString as NSString], type: "Locked")
        server.encryptedValues["pin_code"] = 4 as NSNumber
        try container.save(their: server)
        try container.save(our: Locked(id: id), zone: "Notes")

        let sent = try #require(try container.send(id: id))
        #expect(sent.encryptedValues.changedKeys() == ["pin_code"])
        #expect(sent.encryptedValues["pin_code"] == nil)
    }

    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    @Test func aNewRecordSendsEveryField() throws {
        let container = RecordContainer.inMemory(Memo.self)
        try container.save(our: Memo(id: id, title: "New", subtitle: "Sub"), zone: "Notes")

        let sent = try #require(try container.send(id: id))
        #expect(Set(sent.changedKeys()) == ["id", "title", "subtitle"])
    }
}
#endif
