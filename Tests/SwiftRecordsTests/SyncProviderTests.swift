import Foundation
@testable import SwiftRecords
import Testing

@Record(name: "SyncRecipe")
struct SyncRecipe {
    var id = UUID()
    var title: String
    var servings = 1
    @Renamed(from: "notes") var summary = ""
    var tags: [String] = []
    var updated: Date?
    var steps: [SyncStep] = []
    @Reference(deleteRule: .none) var cook: SyncCook?
    @Asset var photo: Data?
}

@Record
struct SyncStep {
    var id = UUID()
    var text: String
    @Reference(from: \SyncRecipe.steps) var recipes: Set<SyncRecipe.ID> = []
}

@Record
struct SyncCook {
    var id = UUID()
    var name: String
}

/// One device: an in-memory container syncing through its own provider.
@MainActor
struct Device {
    let provider: TestProvider
    let container: RecordContainer
    var context: RecordsContext { container.mainContext }

    init(
        _ server: TestServer, zone: Zone = .inMemory, directory: URL? = nil, mergePolicy: MergePolicy = .default,
        onSignOut: AccountPolicy = .keepLocalData
    ) throws {
        provider = TestProvider(server: server)
        container = try RecordContainer(
            for: [SyncRecipe.self], zone: zone, directory: directory, syncProvider: provider, mergePolicy: mergePolicy,
            onSignOut: onSignOut
        )
        container.mainContext.autosaveEnabled = false
    }

    func recipes() async throws -> [SyncRecipe] {
        try await context.fetch(SyncRecipe.self)
    }

    /// Commits without sending, as the synchronous `save()` does.
    func commit() throws {
        try context.save()
    }

    /// Lets status updates from the sync layer reach the context.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
@Suite struct SyncProviderTests {
    let server = TestServer()

    // MARK: Sending and receiving

    @Test func recordsTravelBetweenDevices() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        let recipe = SyncRecipe(
            title: "Soup", servings: 4, tags: ["winter"], updated: Date(timeIntervalSince1970: 1_000),
            steps: [SyncStep(text: "Chop"), SyncStep(text: "Simmer")], cook: SyncCook(name: "Ana")
        )
        phone.context.save(recipe)
        try await phone.context.save()
        #expect(server.count == 4)

        let sent = try #require(server.record("SyncRecipe", recipe.id)?.fields)
        #expect(sent["title"] as? String == "Soup")
        #expect(sent["servings"] as? Int64 == 4)
        #expect(sent["updated"] as? Date == Date(timeIntervalSince1970: 1_000))
        #expect(sent["steps"] as? [UUID] == recipe.steps.map(\.id))
        #expect(sent["cook"] as? [UUID] == [recipe.cook!.id])
        #expect(sent["tags"] is Data)
        #expect(server.record("SyncStep", recipe.steps[0].id)?.fields?["recipes"] == nil)

        try await tablet.context.refresh()
        let received = try #require(try await tablet.recipes().first)
        #expect(received.id == recipe.id)
        #expect(received.title == "Soup")
        #expect(received.servings == 4)
        #expect(received.tags == ["winter"])
        #expect(received.updated == recipe.updated)
        #expect(received.steps.map(\.text) == ["Chop", "Simmer"])
        #expect(received.cook?.name == "Ana")
        // Inverses are rebuilt on each device.
        #expect(try await tablet.context.fetch(SyncStep.self).map(\.recipes) == [[recipe.id], [recipe.id]])
    }

    @Test func onlyTheAsyncSaveSends() async throws {
        let phone = try Device(server)
        try await phone.context.refresh()   // opening the provider sends what is pending, so open it first
        phone.context.save(SyncRecipe(title: "Toast"))
        try phone.commit()
        #expect(server.count == 0)
        try await phone.context.save()
        #expect(server.count == 1)
        await phone.settle()
        #expect(phone.context.status == .saved)
    }

    @Test func largeUploadsGoInBatches() async throws {
        let phone = try Device(server)
        for index in 0..<450 {
            phone.context.save(SyncCook(name: "Cook \(index)"))
        }
        try await phone.context.save()
        #expect(server.count == 450)
        #expect(phone.provider.sentBatches.map(\.count) == [200, 200, 50])
    }

    @Test func serverChangesAreNotSentBack() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        phone.context.save(SyncRecipe(title: "Pie"))
        try await phone.context.save()
        try await tablet.context.refresh()
        try await tablet.context.refresh()
        #expect(tablet.provider.sentBatches.isEmpty)
        #expect(try tablet.container.store.pendingChanges().isEmpty)
    }

    // MARK: Conflicts

    @Test func editsToDifferentPropertiesBothSurvive() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Stew", servings: 2)
        phone.context.save(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        recipe.title = "Beef stew"
        phone.context.save(recipe)
        var other = try #require(try await tablet.recipes().first)
        other.servings = 6
        tablet.context.save(other)

        try await phone.context.save()
        try await tablet.context.save()   // conflicts, merges and sends the merge
        try await phone.context.refresh()

        for device in [phone, tablet] {
            let merged = try #require(try await device.recipes().first)
            #expect(merged.title == "Beef stew")
            #expect(merged.servings == 6)
        }
    }

    @Test func aTrueClashGoesToTheLatestEdit() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Cake")
        phone.context.save(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        recipe.title = "Lemon cake"
        phone.context.save(recipe)
        try phone.commit()
        recipe.title = "Carrot cake"
        tablet.context.save(recipe)
        try tablet.commit()   // the later edit

        try await phone.context.save()
        try await tablet.context.save()
        try await phone.context.refresh()
        #expect(try await phone.recipes().map(\.title) == ["Carrot cake"])
        #expect(try await tablet.recipes().map(\.title) == ["Carrot cake"])
    }

    @Test func serverWinsDiscardsTheLocalEdit() async throws {
        let phone = try Device(server)
        let tablet = try Device(server, mergePolicy: .serverWins)
        var recipe = SyncRecipe(title: "Salad")
        phone.context.save(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        recipe.servings = 3
        phone.context.save(recipe)
        try await phone.context.save()
        recipe.servings = 1
        recipe.title = "Green salad"
        tablet.context.save(recipe)
        try await tablet.context.save()

        let result = try #require(try await tablet.recipes().first)
        #expect(result.title == "Salad")
        #expect(result.servings == 3)
        #expect(try tablet.container.store.pendingChanges().isEmpty)
    }

    @Test func listsMergeItemByItem() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        let first = SyncStep(text: "First")
        let second = SyncStep(text: "Second")
        var recipe = SyncRecipe(title: "Bread", steps: [first, second])
        phone.context.save(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        var other = recipe
        recipe.steps.append(SyncStep(text: "Bake"))
        phone.context.save(recipe)
        other.steps.insert(SyncStep(text: "Mix"), at: 0)
        tablet.context.save(other)

        try await phone.context.save()
        try await tablet.context.save()
        try await phone.context.refresh()
        try await tablet.context.refresh()
        for device in [phone, tablet] {
            #expect(try await device.recipes().first?.steps.map(\.text) == ["Mix", "First", "Second", "Bake"])
        }
    }

    @Test func listMergeRules() {
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())
        // A removal on either side applies, and each side's insertion keeps its neighbor.
        #expect(SyncMerge.mergeList(local: [a, d, c], server: [a, b, e], base: [a, b, c], preferLocal: false) == [a, d, e])
        // A move made on one side only wins, and an insertion follows its neighbor.
        #expect(SyncMerge.mergeList(local: [c, a, b], server: [a, b, c, d], base: [a, b, c], preferLocal: false) == [c, d, a, b])
        // Without an ancestor: the union, in the preferred order.
        #expect(SyncMerge.mergeList(local: [a, c], server: [b, a], base: nil, preferLocal: true) == [b, a, c])
    }

    @Test func aDeleteBeatsAnEditMadeElsewhere() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Tart", steps: [SyncStep(text: "Roll")])
        phone.context.save(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        phone.context.delete(recipe)
        try await phone.context.save()
        recipe.title = "Apple tart"
        tablet.context.save(recipe)
        try await tablet.context.save()   // the server answers with its deletion

        #expect(try await tablet.recipes().isEmpty)
        #expect(try await tablet.context.fetch(SyncStep.self).isEmpty)
        #expect(server.count == 0)
    }

    @Test func aLocalDeleteBeatsAServerEdit() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Jam")
        phone.context.save(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        tablet.context.delete(recipe)
        try tablet.commit()
        recipe.title = "Plum jam"
        phone.context.save(recipe)
        try await phone.context.save()
        await tablet.provider.fetch()   // the edit arrives before the delete is sent
        #expect(try await tablet.recipes().isEmpty)

        try await tablet.context.save()
        try await phone.context.refresh()
        #expect(try await phone.recipes().isEmpty)
    }

    // MARK: Arrival order and newer versions

    @Test func linksArrivingBeforeTheirTargetsResolveLater() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let step = SyncStep(text: "Whisk")
        let recipeID = UUID()
        await phone.provider.emit(.received([
            SyncRecord(type: "SyncRecipe", id: recipeID, fields: ["title": "Omelette", "steps": [step.id]]),
        ], state: nil))
        var recipe = try #require(try await phone.recipes().first)
        #expect(recipe.steps.isEmpty)

        // Saving the recipe here keeps the link it can't see yet.
        recipe.title = "Cheese omelette"
        phone.context.save(recipe)
        try phone.commit()
        await phone.provider.emit(.received([
            SyncRecord(type: "SyncStep", id: step.id, fields: ["text": "Whisk"]),
        ], state: nil))
        #expect(try await phone.recipes().first?.steps.map(\.text) == ["Whisk"])
    }

    @Test func fieldsFromNewerVersionsAreKeptAndSentBack() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let id = UUID()
        await phone.provider.emit(.received([
            SyncRecord(type: "SyncRecipe", id: id, fields: ["title": "Curry", "spice": Int64(3)], tag: nil),
        ], state: nil))
        var recipe = try #require(try await phone.recipes().first)
        recipe.title = "Green curry"
        phone.context.save(recipe)
        try await phone.context.save()

        let sent = try #require(server.record("SyncRecipe", id)?.fields)
        #expect(sent["title"] as? String == "Green curry")
        #expect(sent["spice"] as? Int64 == 3)
    }

    @Test func oldPropertyNamesAreReadFromFields() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        await phone.provider.emit(.received([
            SyncRecord(type: "SyncRecipe", id: UUID(), fields: ["title": "Rice", "notes": "Rinse first"]),
        ], state: nil))
        #expect(try await phone.recipes().first?.summary == "Rinse first")
    }

    @Test func recordsThatDontDecodeAreKept() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let id = UUID()
        await phone.provider.emit(.received([
            SyncRecord(type: "SyncRecipe", id: id, fields: ["title": "Odd", "servings": "lots"]),
            SyncRecord(type: "Unknown", id: UUID(), fields: ["x": "y"]),
            SyncRecord(type: "SyncRecipe", id: UUID(), fields: ["title": "Fine"]),
        ], state: nil))
        await phone.settle()
        #expect(phone.context.status == .failed(.incompatibleRecord(type: "SyncRecipe", id: id)))
        #expect(try await phone.recipes().map(\.title) == ["Fine"])
        let parked = try phone.container.store.db.run("SELECT COUNT(*) AS n FROM \"_records_parked\"")
        #expect(parked.first?["n"] == .integer(2))
    }

    @Test func assetsTravelAsFiles() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Photo")
        recipe.photo = Data([1, 2, 3])
        phone.context.save(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()
        let received = try #require(try await tablet.recipes().first)
        #expect(received.photo == Data([1, 2, 3]))
        #expect(received.$photo.url?.path.hasPrefix(tablet.container.assetsDirectory.path) == true)
    }

    // MARK: Status

    @Test func statusFollowsTheServer() async throws {
        let phone = try Device(server)
        server.isOnline = false
        phone.context.save(SyncRecipe(title: "Offline"))
        try await phone.context.save()
        await phone.settle()
        #expect(phone.context.status == .offline)
        try await phone.context.refresh()   // being offline isn't an error

        server.isOnline = true
        try await phone.context.refresh()
        await phone.settle()
        #expect(phone.context.status == .saved)
        #expect(server.count == 1)

        server.isFull = true
        phone.context.save(SyncRecipe(title: "Too much"))
        await #expect(throws: RecordsError.storageFull) { try await phone.context.refresh() }
        await phone.settle()
        #expect(phone.context.status == .failed(.storageFull))

        server.isFull = false
        server.rejectedTypes = ["SyncCook"]
        let cook = SyncCook(name: "Refused")
        phone.context.save(cook)
        try await phone.context.save()
        await phone.settle()
        #expect(phone.context.status == .failed(.rejected(type: "SyncCook", id: cook.id)))
    }

    @Test func localContainersReportStatusToo() async throws {
        let context = try RecordContainer(zone: .inMemory).mainContext
        context.autosaveEnabled = false
        #expect(context.status == .saved)
        context.save(Measurement(value: .nan))
        await #expect(throws: RecordsError.self) { try await context.save() }
        #expect(context.status == .failed(.invalidValue(type: "Measurement", property: "value")))
        context.rollback()
        context.save(Measurement(value: 1))
        try await context.save()
        #expect(context.status == .saved)
        try await context.refresh()
    }

    // MARK: Accounts and resets

    @Test func signingOutKeepsLocalDataByDefault() async throws {
        let phone = try Device(server)
        phone.context.save(SyncRecipe(title: "Mine"))
        try await phone.context.save()
        await phone.provider.emit(.accountChanged(nil))
        await phone.settle()
        #expect(phone.context.status == .signedOut)
        #expect(try await phone.recipes().count == 1)

        // Edits while signed out wait for the next account.
        phone.context.save(SyncRecipe(title: "Later"))
        try await phone.context.save()
        #expect(server.count == 1)
        await phone.provider.emit(.accountChanged("alice"))
        await phone.settle()
        #expect(server.count == 2)
        #expect(phone.context.status == .saved)
    }

    @Test func signingOutCanDeleteLocalData() async throws {
        let phone = try Device(server, onSignOut: .deleteLocalData)
        phone.context.save(SyncRecipe(title: "Mine"))
        try await phone.context.save()
        await phone.provider.emit(.accountChanged(nil))
        #expect(try await phone.recipes().isEmpty)
        #expect(server.count == 1)
    }

    @Test func switchingAccountsDeletesTheOldAccountsData() async throws {
        let phone = try Device(server)
        phone.context.save(SyncRecipe(title: "Alice's"))
        try await phone.context.save()
        await phone.provider.emit(.accountChanged("bob"))
        #expect(try await phone.recipes().isEmpty)
    }

    @Test func aServerResetUploadsEverythingAgain() async throws {
        let phone = try Device(server)
        phone.context.save(SyncRecipe(title: "Keep", steps: [SyncStep(text: "One")]))
        try await phone.context.save()
        server.reset()
        await phone.provider.emit(.serverReset)
        #expect(server.count == 2)
        #expect(try phone.container.store.pendingChanges().isEmpty)
    }

    @Test func aFirstSignInUploadsExistingRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let local = try RecordContainer(zone: "kitchen", directory: directory)
            try local.save(SyncRecipe(title: "Before sync"))
        }
        let phone = try Device(server, zone: "kitchen", directory: directory)
        try await phone.context.refresh()
        #expect(server.count == 1)
    }

    @Test func changesSentBeforeACrashAreSentAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recipe = SyncRecipe(title: "Unacknowledged")
        do {
            let phone = try Device(server, zone: "kitchen", directory: directory)
            phone.provider.dropsAcknowledgements = true
            phone.context.save(recipe)
            try await phone.context.save()
            #expect(server.count == 1)
            #expect(try phone.container.store.pendingChanges().count == 1)
        }
        let relaunched = try Device(server, zone: "kitchen", directory: directory)
        try await relaunched.context.refresh()
        #expect(relaunched.provider.sentBatches.first?.map(\.id) == [recipe.id])
        #expect(try relaunched.container.store.pendingChanges().isEmpty)
        #expect(try await relaunched.recipes().map(\.title) == ["Unacknowledged"])
    }
}
