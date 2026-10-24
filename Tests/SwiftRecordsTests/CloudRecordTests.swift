import Foundation
@testable import SwiftRecords
import Testing

/// Records as CloudKit holds them: plain fields, children as lists of record names, and one reference
/// from each child to its parent.
@MainActor
@Suite struct CloudRecordTests {
    let server = TestServer()

    @Test func recordsMapFieldForField() async throws {
        let phone = try Device(server)
        var recipe = SyncRecipe(
            title: "Soup", servings: 4, tags: ["winter"], updated: Date(timeIntervalSince1970: 1_000),
            steps: [SyncStep(text: "Chop"), SyncStep(text: "Simmer")], cook: SyncCook(name: "Ana")
        )
        recipe.photo = Data([1, 2, 3])
        phone.context.insert(recipe)
        try await phone.context.save()

        let saved = try #require(server.record("SyncRecipe", recipe.id))
        let cloud = try #require(try phone.container.cloudRecord(for: saved))
        #expect(cloud.type == "SyncRecipe")
        #expect(cloud.fields["title"] == .string("Soup"))
        #expect(cloud.fields["servings"] == .int(4))
        #expect(cloud.fields["tags"] == .strings(["winter"]))
        #expect(cloud.fields["updated"] == .date(Date(timeIntervalSince1970: 1_000)))
        // Children are plain record names in order, not references.
        #expect(cloud.fields["steps"] == .strings(recipe.steps.map(\.id.uuidString)))
        #expect(cloud.fields["cook"] == .strings([recipe.cook!.id.uuidString]))
        guard case .asset(let file)? = cloud.fields["photo"] else {
            Issue.record("The photo isn't an asset")
            return
        }
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))

        let savedStep = try #require(server.record("SyncStep", recipe.steps[0].id))
        let step = try #require(try phone.container.cloudRecord(for: savedStep))
        #expect(step.fields["recipe"] == .reference(recipe.id, action: .deleteSelf))
        #expect(step.fields["recipes"] == nil)
        #expect(step.fields["text"] == .string("Chop"))
    }

    @Test func recordsComeBackUnchanged() async throws {
        let phone = try Device(server)
        let recipe = SyncRecipe(
            title: "Soup", servings: 4, tags: ["winter", "hot"], updated: Date(timeIntervalSince1970: 1_000.123),
            steps: [SyncStep(text: "Chop")], cook: nil
        )
        phone.context.insert(recipe)
        try await phone.context.save()
        let store = phone.container.defaultStorage.store

        for (type, id) in [("SyncRecipe", recipe.id), ("SyncStep", recipe.steps[0].id)] {
            let original = try #require(server.record(type, id))
            let cloud = try #require(try phone.container.cloudRecord(for: original))
            let back = try phone.container.change(from: cloud, zone: .default, owner: nil, synced: original.synced)
            #expect(try store.syncRecord(from: back).fields == store.syncRecord(from: original).fields)
        }
        #expect(try phone.container.cloudRecord(for: .delete(id: recipe.id, zone: .default, type: "SyncRecipe", owner: nil, synced: nil)) == nil)
    }

    @Test func fieldsFromNewerVersionsKeepTheirShape() throws {
        let phone = try Device(server)
        let id = UUID()
        let json = #"{"title":"Soup","servings":2,"steps":[],"cook":[],"rating":4.5,"labels":["a","b"],"extra":{"x":1}}"#
        let change = RecordChangeData.save(id: id, zone: .default, type: "SyncRecipe", json: Data(json.utf8), owner: nil, synced: nil)

        let cloud = try #require(try phone.container.cloudRecord(for: change))
        #expect(cloud.fields["rating"] == .double(4.5))
        #expect(cloud.fields["labels"] == .strings(["a", "b"]))
        guard case .bytes(let extra)? = cloud.fields["extra"] else {
            Issue.record("An object field isn't JSON data")
            return
        }
        #expect(try JSONSerialization.jsonObject(with: extra) as? [String: Int] == ["x": 1])

        let store = phone.container.defaultStorage.store
        let back = try phone.container.change(from: cloud, zone: .default, owner: nil, synced: nil)
        #expect(try store.syncRecord(from: back).fields == store.syncRecord(from: change).fields)
    }

    @Test func structsMapAsStoredRecordsDo() async throws {
        let phone = try Device(server)
        var recipe = SyncRecipe(
            title: "Soup", servings: 4, tags: ["winter", "hot"], updated: Date(timeIntervalSince1970: 1_000.123),
            steps: [SyncStep(text: "Chop"), SyncStep(text: "Simmer")], cook: SyncCook(name: "Ana")
        )
        recipe.photo = Data([1, 2, 3])
        let plain = try RecordStore.cloudRecord(of: recipe)

        phone.context.insert(recipe)
        try await phone.context.save()
        let saved = try #require(server.record("SyncRecipe", recipe.id))
        let stored = try #require(try phone.container.cloudRecord(for: saved))
        #expect(plain.type == stored.type)
        #expect(plain.id == stored.id)
        // The asset is a file in each case, just not the same file.
        #expect(plain.fields.filter { $0.key != "photo" } == stored.fields.filter { $0.key != "photo" })
        guard case .asset(let file)? = plain.fields["photo"] else {
            Issue.record("The photo isn't an asset")
            return
        }
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))

        // A step holds its parent once saved through it, and then maps as the stored step does.
        var step = recipe.steps[0]
        step.recipe = recipe.id
        let savedStep = try #require(server.record("SyncStep", step.id))
        let storedStep = try phone.container.cloudRecord(for: savedStep)
        #expect(try RecordStore.cloudRecord(of: step) == storedStep)
    }

    @Test func aStructNeverSavedMapsFromItsValuesAlone() throws {
        let recipe = SyncRecipe(title: "Toast")
        let cloud = try RecordStore.cloudRecord(of: recipe)
        #expect(cloud == CloudRecord(type: "SyncRecipe", id: recipe.id, fields: [
            "title": .string("Toast"), "servings": .int(1), "summary": .string(""), "tags": .strings([]),
        ]))
        // A child that isn't linked yet has no reference.
        #expect(try RecordStore.cloudRecord(of: SyncStep(text: "Chop")).fields == ["text": .string("Chop")])
    }

    @Test func aPropertyThatWontEncodeThrows() {
        #expect(throws: RecordsError.self) { try RecordStore.cloudRecord(of: Unencodable()) }
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
        let store = phone.container.defaultStorage.store

        let saved = try #require(server.record("SyncRecipe", recipe.id))
        let record = try #require(try phone.container.ckRecord(for: saved, in: zoneID))
        #expect(record.recordID.recordName == recipe.id.uuidString)
        #expect(record.recordType == "SyncRecipe")
        #expect(record["title"] as? String == "Soup")
        #expect(record["servings"] as? Int64 == 4)
        #expect(record["tags"] as? [String] == ["winter"])
        #expect(record["steps"] as? [String] == [recipe.steps[0].id.uuidString])
        #expect(record["photo"] is CKAsset)

        let (back, assets) = try phone.container.change(from: record, zone: .default)
        #expect(assets.count == 1)
        #expect(try store.syncRecord(from: back).fields?["title"] == .string("Soup"))
        #expect(try store.syncRecord(from: back).fields?["steps"] == .ids([recipe.steps[0].id]))

        let savedStep = try #require(server.record("SyncStep", recipe.steps[0].id))
        let step = try #require(try phone.container.ckRecord(for: savedStep, in: zoneID))
        let reference = try #require(step["recipe"] as? CKRecord.Reference)
        #expect(reference.recordID.recordName == recipe.id.uuidString)
        #expect(reference.action == .deleteSelf)
        let (stepBack, _) = try phone.container.change(from: step, zone: .default)
        #expect(try store.syncRecord(from: stepBack).fields == store.syncRecord(from: savedStep).fields)
    }

    @Test func structsEncodeWithoutAContainer() throws {
        var recipe = SyncRecipe(title: "Soup", servings: 4, tags: ["winter"], steps: [SyncStep(text: "Chop")])
        recipe.photo = Data([1, 2, 3])
        let custom = CKRecordZone.ID(zoneName: "recipes", ownerName: CKCurrentUserDefaultName)

        let record = try CKRecordEncoder(zone: "recipes").encode(recipe)
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

    @Test func zonesThatNeverSyncThrow() {
        for zone in [Zone.inMemory, .localOnly] {
            #expect(throws: RecordsError.unsyncedZone(zone)) { try CKRecordEncoder(zone: zone).encode(SyncRecipe(title: "Soup")) }
        }
    }
}
#endif
