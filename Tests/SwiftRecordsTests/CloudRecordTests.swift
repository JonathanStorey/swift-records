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

    @Test func structsMapAsStoredRecordsDo() async throws {
        let phone = try Device(server)
        var recipe = SyncRecipe(
            title: "Soup", servings: 4, tags: ["winter", "hot"], updated: Date(timeIntervalSince1970: 1_000.123),
            steps: [SyncStep(text: "Chop"), SyncStep(text: "Simmer")], cooks: [SyncCook(name: "Ana")]
        )
        recipe.photo = Data([1, 2, 3])
        let plain = try RecordStore.recordValues(of: recipe)

        phone.context.insert(recipe)
        try await phone.context.save()
        let stored = try #require(server.record("SyncRecipe", recipe.id)?.fields)
        // The asset is a file in each case, just not the same file.
        #expect(plain.values.filter { $0.key != "photo" } == stored.filter { $0.key != "photo" })
        guard case .asset(let id)? = plain.values["photo"], let file = plain.files[id] else {
            Issue.record("The photo isn't an asset")
            return
        }
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))

        // A step holds its parent once saved through it, and then maps as the stored step does.
        var step = recipe.steps[0]
        step.recipe = recipe.id
        #expect(try RecordStore.recordValues(of: step).values == server.record("SyncStep", step.id)?.fields)
    }

    @Test func aStructNeverSavedMapsFromItsValuesAlone() throws {
        let recipe = SyncRecipe(title: "Toast")
        #expect(try RecordStore.recordValues(of: recipe).values == [
            "title": .string("Toast"), "servings": .int(1), "summary": .string(""), "tags": .strings([]),
        ])
        // A child that isn't linked yet has no reference.
        #expect(try RecordStore.recordValues(of: SyncStep(text: "Chop")).values == ["text": .string("Chop")])
    }

    @Test func aPropertyThatWontEncodeThrows() {
        #expect(throws: RecordsError.self) { try RecordStore.recordValues(of: Unencodable()) }
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

/// A value whose `encode(to:)` always fails.
struct Refusing: Codable, Sendable {
    func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Refused"))
    }
}

@Record
struct Unencodable {
    var id = UUID()
    var value = Refusing()
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
        #expect(record["steps"] as? [String] == [recipe.steps[0].id.uuidString])
        #expect(record["photo"] is CKAsset)

        let (back, assets) = try phone.container.change(from: record, zone: .default)
        #expect(assets.count == 1)
        #expect(back.tag != nil)
        // The archived system fields bring back the same record.
        let again = try #require(try phone.container.ckRecord(for: back, in: zoneID))
        #expect(again.recordID == record.recordID)
        #expect(try store.syncRecord(from: back).fields?["title"] == .string("Soup"))
        #expect(try store.syncRecord(from: back).fields?["steps"] == .ids([recipe.steps[0].id]))

        var savedStep = try #require(server.record("SyncStep", recipe.steps[0].id))
        savedStep.tag = nil
        let step = try #require(try phone.container.ckRecord(for: savedStep, in: zoneID))
        let reference = try #require(step["recipe"] as? CKRecord.Reference)
        #expect(reference.recordID.recordName == recipe.id.uuidString)
        #expect(reference.action == .deleteSelf)
        let (stepBack, _) = try phone.container.change(from: step, zone: .default)
        #expect(try store.syncRecord(from: stepBack).fields == store.syncRecord(from: savedStep).fields)
    }

    @Test func aTagFromAnotherServerThrows() throws {
        let phone = try Device(server)
        let change = RecordChangeData(id: UUID(), zone: .default, type: "SyncRecipe", fields: [:], tag: Data("1700000000000".utf8))
        #expect(throws: RecordsError.self) { try phone.container.ckRecord(for: change, in: zoneID) }
    }

    @Test func structsEncodeWithoutAContainer() throws {
        var recipe = SyncRecipe(title: "Soup", servings: 4, tags: ["winter"], steps: [SyncStep(text: "Chop")])
        recipe.photo = Data([1, 2, 3])
        let custom = CKRecordZone.ID(zoneName: "recipes", ownerName: CKCurrentUserDefaultName)

        let record = try CKRecordEncoder().encode(recipe, zone: "recipes")
        #expect(record.recordID == CKRecord.ID(recordName: recipe.id.uuidString, zoneID: custom))
        #expect(record.recordType == "SyncRecipe")
        #expect(record.recordChangeTag == nil)
        #expect(record["title"] as? String == "Soup")
        #expect(record["servings"] as? Int64 == 4)
        #expect(record["tags"] as? [String] == ["winter"])
        #expect(record["steps"] as? [String] == [recipe.steps[0].id.uuidString])
        let asset = try #require(record["photo"] as? CKAsset)
        let file = try #require(asset.fileURL)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        #expect(record["cook"] == nil)

        var step = recipe.steps[0]
        step.recipe = recipe.id
        let reference = try #require(try CKRecordEncoder().encode(step)["recipe"] as? CKRecord.Reference)
        #expect(reference.recordID.recordName == recipe.id.uuidString)
        #expect(reference.recordID.zoneID == CKRecordZone.default().zoneID)
        #expect(reference.action == .deleteSelf)
    }

    @Test func systemFieldsMakeAnUpdate() throws {
        var recipe = SyncRecipe(title: "Soup")
        let home = CKRecordZone.default().zoneID
        let server = CKRecord(recordType: "SyncRecipe", recordID: CKRecord.ID(recordName: recipe.id.uuidString, zoneID: home))
        server["title"] = "Soup"
        server["summary"] = "Gone"
        let archived = Self.systemFields(of: server)

        recipe.title = "Stew"
        let record = try CKRecordEncoder().encode(recipe, systemFields: archived)
        #expect(record.recordID == server.recordID)
        #expect(record["title"] as? String == "Stew")
        // System fields carry no values, so nothing of the server's copy survives but its identity.
        #expect(record["summary"] as? String == "")
        #expect(try CKRecordEncoder().encode(recipe, systemFields: nil).recordID == server.recordID)
    }

    @Test func systemFieldsForAnotherRecordThrow() {
        let recipe = SyncRecipe(title: "Soup")
        let home = CKRecordZone.default().zoneID
        let other = CKRecord(recordType: "SyncRecipe", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: home))
        let wrongType = CKRecord(recordType: "SyncStep", recordID: CKRecord.ID(recordName: recipe.id.uuidString, zoneID: home))
        let wrongZone = CKRecord(
            recordType: "SyncRecipe",
            recordID: CKRecord.ID(recordName: recipe.id.uuidString, zoneID: CKRecordZone.ID(zoneName: "elsewhere", ownerName: CKCurrentUserDefaultName))
        )
        for server in [other, wrongType, wrongZone] {
            #expect(throws: RecordsError.mismatchedSystemFields(type: "SyncRecipe", id: recipe.id)) {
                try CKRecordEncoder().encode(recipe, systemFields: Self.systemFields(of: server))
            }
        }
        #expect(throws: RecordsError.mismatchedSystemFields(type: "SyncRecipe", id: recipe.id)) {
            try CKRecordEncoder().encode(recipe, systemFields: Data("not an archive".utf8))
        }
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    @Test func zonesThatNeverSyncThrow() {
        for zone in [Zone.inMemory, .localOnly] {
            #expect(throws: RecordsError.unsyncedZone(zone)) { try CKRecordEncoder().encode(SyncRecipe(title: "Soup"), zone: zone) }
        }
    }
}
#endif
