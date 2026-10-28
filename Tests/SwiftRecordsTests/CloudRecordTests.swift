import Foundation
@testable import SwiftRecords
import Testing

/// Records as they cross to a server: plain values and a reference from each child to its parent. A
/// parent holds no list of its children, and each many-to-many pair is a link record of its own.
@MainActor
@Suite struct RecordValueTests {
    let server = TestServer()

    @Test func recordsMapFieldForField() async throws {
        let phone = try Device(server)
        var recipe = SyncRecipe(
            title: "Soup", servings: 4, tags: ["winter"], updated: Date(timeIntervalSince1970: 1_000),
            steps: [SyncStep(text: "Chop"), SyncStep(text: "Simmer")], cooks: [SyncCook(name: "Ana")]
        )
        recipe.photo = Data([1, 2, 3])
        phone.context.insert(recipe)
        try await phone.context.save()

        let saved = try #require(server.record("SyncRecipe", recipe.id))
        let fields = try #require(saved.fields)
        #expect(saved.type == "SyncRecipe")
        #expect(fields["title"] == .string("Soup"))
        #expect(fields["servings"] == .int(4))
        #expect(fields["tags"] == .strings(["winter"]))
        #expect(fields["updated"] == .date(Date(timeIntervalSince1970: 1_000)))
        // Neither relationship is a field: the steps point here, and the cook is linked by a record of its own.
        #expect(fields["steps"] == nil)
        #expect(fields["cooks"] == nil)
        let linkID = _RecordLink.id(relation: "SyncRecipe.cooks", from: recipe.id, to: recipe.cooks[0].id)
        let link = try #require(server.record("RecordLink", linkID)?.fields)
        #expect(link["relation"] == .string("SyncRecipe.cooks"))
        #expect(link["from"] == .reference(recipe.id, action: .deleteSelf))
        #expect(link["to"] == .reference(recipe.cooks[0].id, action: .deleteSelf))
        guard case .asset(let id)? = fields["photo"] else {
            Issue.record("The photo isn't an asset")
            return
        }
        #expect(try Data(contentsOf: phone.container.initialStorage.store.assetURL(named: id)) == Data([1, 2, 3]))

        let step = try #require(server.record("SyncStep", recipe.steps[0].id)?.fields)
        #expect(step["recipe"] == .reference(recipe.id, action: .deleteSelf))
        #expect(step["text"] == .string("Chop"))
    }

    @Test func recordsComeBackUnchanged() async throws {
        let phone = try Device(server)
        let recipe = SyncRecipe(
            title: "Soup", servings: 4, tags: ["winter", "hot"], updated: Date(timeIntervalSince1970: 1_000.123),
            steps: [SyncStep(text: "Chop")]
        )
        phone.context.insert(recipe)
        try await phone.context.save()
        let store = phone.container.initialStorage.store

        for (type, id) in [("SyncRecipe", recipe.id), ("SyncStep", recipe.steps[0].id)] {
            let original = try #require(server.record(type, id))
            let back = try store.change(for: store.syncRecord(from: original), zone: .default)
            #expect(back.fields == original.fields)
            #expect(back.tag == original.tag)
        }
    }

    @Test func fieldsFromNewerVersionsKeepTheirShape() throws {
        let phone = try Device(server)
        let change = RecordChangeData(id: UUID(), zone: .default, type: "SyncRecipe", fields: [
            "title": .string("Soup"), "servings": .int(2), "rating": .double(4.5), "labels": .strings(["a", "b"]),
            "extra": .bytes(Data(#"{"x":1}"#.utf8)), "link": .reference(UUID(), action: .nullify),
        ])
        let store = phone.container.initialStorage.store
        let back = try store.change(for: store.syncRecord(from: change), zone: .default)
        #expect(back.fields == change.fields)
    }

    @Test func valuesEncodeAsSingleKeyObjects() throws {
        let id = UUID()
        let values: [String: RecordValue] = [
            "a": .string("Soup"), "b": .int(4), "c": .reference(id, action: .deleteSelf), "d": .reference(id, action: .nullify),
        ]
        let json = String(decoding: try WireJSON.encoder.encode(values), as: UTF8.self)
        #expect(json == #"{"a":{"string":"Soup"},"b":{"int":4},"c":{"action":"deleteSelf","reference":"\#(id)"},"d":{"reference":"\#(id)"}}"#)
        #expect(try WireJSON.decoder.decode([String: RecordValue].self, from: Data(json.utf8)) == values)
    }
}

#if canImport(CloudKit)
import CloudKit

@MainActor
@Suite struct CKRecordTests {
    let server = TestServer()
    let zoneID = CKRecordZone.ID(zoneName: "default", ownerName: CKCurrentUserDefaultName)

    @Test func savesBecomeCKRecordsAndBack() async throws {
        let phone = try Device(server)
        var recipe = SyncRecipe(title: "Soup", servings: 4, tags: ["winter"], steps: [SyncStep(text: "Chop")])
        recipe.photo = Data([1, 2, 3])
        phone.context.insert(recipe)
        try await phone.context.save()
        let store = phone.container.initialStorage.store

        // The test server's tags aren't CloudKit's system fields, so these copies go as new records.
        var saved = try #require(server.record("SyncRecipe", recipe.id))
        saved.tag = nil
        let record = try #require(try phone.container.ckRecord(for: saved, in: zoneID))
        #expect(record.recordChangeTag == nil)
        #expect(record.recordID.recordName == recipe.id.uuidString)
        #expect(record.recordType == "SyncRecipe")
        #expect(record["title"] as? String == "Soup")
        #expect(record["servings"] as? Int64 == 4)
        #expect(record["tags"] as? [String] == ["winter"])
        #expect(record["steps"] == nil)
        #expect(record.parent == nil)
        #expect(record["photo"] is CKAsset)

        let (back, assets) = try phone.container.change(from: record, zone: .default)
        #expect(assets.count == 1)
        #expect(back.tag != nil)
        // The archived system fields bring back the same record.
        let again = try #require(try phone.container.ckRecord(for: back, in: zoneID))
        #expect(again.recordID == record.recordID)
        #expect(try store.syncRecord(from: back).fields?["title"] == .string("Soup"))
        #expect(try store.syncRecord(from: back).fields?["steps"] == nil)

        var savedStep = try #require(server.record("SyncStep", recipe.steps[0].id))
        savedStep.tag = nil
        let step = try #require(try phone.container.ckRecord(for: savedStep, in: zoneID))
        let reference = try #require(step["recipe"] as? CKRecord.Reference)
        #expect(reference.recordID.recordName == recipe.id.uuidString)
        #expect(reference.action == .deleteSelf)
        // A step belongs to its recipe, which is how a share of the recipe includes it.
        #expect(step.parent?.recordID == record.recordID)
        let (stepBack, _) = try phone.container.change(from: step, zone: .default)
        #expect(try store.syncRecord(from: stepBack).fields == store.syncRecord(from: savedStep).fields)
    }

    @Test func aTagFromAnotherServerThrows() throws {
        let phone = try Device(server)
        let change = RecordChangeData(id: UUID(), zone: .default, type: "SyncRecipe", fields: [:], tag: Data("1700000000000".utf8))
        #expect(throws: RecordsError.self) { try phone.container.ckRecord(for: change, in: zoneID) }
    }

    @Test func systemFieldsMakeAnUpdate() throws {
        let phone = try Device(server)
        let id = UUID()
        let copy = CKRecord(recordType: "SyncRecipe", recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
        copy["title"] = "Soup"
        copy["summary"] = "Gone"
        let change = RecordChangeData(id: id, zone: .default, type: "SyncRecipe", fields: ["title": .string("Stew")], tag: Self.systemFields(of: copy))

        let record = try #require(try phone.container.ckRecord(for: change, in: zoneID))
        #expect(record.recordID == copy.recordID)
        #expect(record["title"] as? String == "Stew")
        // System fields carry no values, so nothing of the server's copy survives but its identity.
        #expect(record["summary"] == nil)
    }

    @Test func systemFieldsForAnotherRecordThrow() throws {
        let phone = try Device(server)
        let id = UUID()
        let other = CKRecord(recordType: "SyncRecipe", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        let wrongType = CKRecord(recordType: "SyncStep", recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))
        let wrongZone = CKRecord(
            recordType: "SyncRecipe",
            recordID: CKRecord.ID(recordName: id.uuidString, zoneID: CKRecordZone.ID(zoneName: "elsewhere", ownerName: CKCurrentUserDefaultName))
        )
        let tags = [other, wrongType, wrongZone].map { Self.systemFields(of: $0) } + [Data("not an archive".utf8)]
        for tag in tags {
            let change = RecordChangeData(id: id, zone: .default, type: "SyncRecipe", fields: [:], tag: tag)
            #expect(throws: RecordsError.mismatchedSystemFields(type: "SyncRecipe", id: id)) {
                try phone.container.ckRecord(for: change, in: zoneID)
            }
        }
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
}
#endif
