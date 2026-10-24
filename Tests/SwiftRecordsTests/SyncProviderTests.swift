import Foundation
@testable import SwiftRecords
import Testing

@Record("SyncRecipe")
struct SyncRecipe {
    var id = UUID.ordered()
    var title: String
    var servings = 1
    @Renamed(from: "notes") var summary = ""
    var tags: [String] = []
    var updated: Date?
    var steps: [SyncStep] = []
    var cook: SyncCook?
    @Asset var photo: Data?
}

@Record
struct SyncStep {
    var id = UUID.ordered()
    var text: String
    @Reference(to: \SyncRecipe.steps, action: .deleteSelf) var recipe: SyncRecipe.ID?
    @Reference(from: \SyncRecipe.steps) var recipes: Set<SyncRecipe.ID>
}

@Record
struct SyncCook {
    var id = UUID.ordered()
    var name: String
    @Reference(from: \SyncRecipe.cook) var recipeIDs: Set<SyncRecipe.ID>
}

/// One device: an in-memory container syncing through its own provider.
@MainActor
struct Device {
    let provider: TestProvider
    let container: RecordContainer
    var context: RecordContext { container.mainContext }

    init(
        _ server: TestServer, directory: URL? = nil, account: String?? = nil, publicZones: Set<Zone> = [],
        mergePolicy: MergePolicy = .default, onSignOut: AccountPolicy = .keepLocalData,
        onAccountSwitch: AccountPolicy = .deleteLocalData
    ) throws {
        let provider = TestProvider(server: server, account: account)
        self.provider = provider
        container = try RecordContainer(
            for: [SyncRecipe.self], directory: directory, inMemory: directory == nil, syncProvider: { _ in provider },
            publicZones: publicZones, mergePolicy: mergePolicy, onSignOut: onSignOut, onAccountSwitch: onAccountSwitch
        )
        container.mainContext.autosaveEnabled = false
    }

    func recipes() async throws -> [SyncRecipe] {
        try context.fetch(SyncRecipe.self)
    }

    /// Commits without sending, as the synchronous `save()` does.
    func commit() throws {
        try context.save()
    }

    /// Downloads the server's changes without uploading, as if they arrived before anything was sent.
    func download() async {
        await container.defaultStorage.sync?.download()
        await settle()
    }

    /// Waits for the background asset transfers, then lets their progress reach the context.
    func transfers() async {
        await container.defaultStorage.sync?.transfers()
        await settle()
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
        phone.context.insert(recipe)
        try await phone.context.save()
        #expect(server.count == 4)

        // The JSON reads like the record: plain values, dates in milliseconds, relationships as IDs.
        #expect(server.value("SyncRecipe", recipe.id, "title", as: String.self) == "Soup")
        #expect(server.value("SyncRecipe", recipe.id, "servings", as: Int.self) == 4)
        #expect(server.value("SyncRecipe", recipe.id, "updated", as: Double.self) == 1_000_000)
        #expect(server.value("SyncRecipe", recipe.id, "steps", as: [UUID].self) == recipe.steps.map(\.id))
        #expect(server.value("SyncRecipe", recipe.id, "cook", as: [UUID].self) == [recipe.cook!.id])
        #expect(server.value("SyncRecipe", recipe.id, "tags", as: [String].self) == ["winter"])
        #expect(server.value("SyncStep", recipe.steps[0].id, "recipe", as: UUID.self) == recipe.id)
        #expect(!server.has("SyncStep", recipe.steps[0].id, "recipes"))
        #expect(server.record("SyncRecipe", recipe.id)?.synced != nil)

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
        #expect(try tablet.context.fetch(SyncStep.self).map(\.recipes) == [[recipe.id], [recipe.id]])
    }

    @Test func refreshUpdatesViewsBeforeReturning() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        try await tablet.context.refresh()
        var refreshes = 0
        let view = NSObject()
        tablet.context.onChange(for: view) { refreshes += 1 }

        phone.context.insert(SyncRecipe(title: "Toast"))
        try await phone.context.save()
        try await tablet.context.refresh()
        // A pull-to-refresh spinner stops when this returns, so views must already show the new record.
        #expect(refreshes > 0)
        let stored = try tablet.container.defaultStorage.fetch(SyncRecipe.self)
        #expect(tablet.context.overlay(stored, in: .default) { _ in true }.map(\.title) == ["Toast"])
    }

    @Test func onlyTheAsyncSaveSends() async throws {
        let phone = try Device(server)
        try await phone.context.refresh()   // opening the provider sends what is pending, so open it first
        phone.context.insert(SyncRecipe(title: "Toast"))
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
            phone.context.insert(SyncCook(name: "Cook \(index)"))
        }
        try await phone.context.save()
        #expect(server.count == 450)
        #expect(phone.provider.sentBatches.map(\.count) == [200, 200, 50])
    }

    @Test func serverChangesAreNotSentBack() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        phone.context.insert(SyncRecipe(title: "Pie"))
        try await phone.context.save()
        try await tablet.context.refresh()
        try await tablet.context.refresh()
        #expect(tablet.provider.sentBatches.isEmpty)
        #expect(try tablet.container.defaultStorage.store.pendingChanges().isEmpty)
    }

    // MARK: Conflicts

    @Test func editsToDifferentPropertiesBothSurvive() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Stew", servings: 2)
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        recipe.title = "Beef stew"
        phone.context.insert(recipe)
        var other = try #require(try await tablet.recipes().first)
        other.servings = 6
        tablet.context.insert(other)

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
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        recipe.title = "Lemon cake"
        phone.context.insert(recipe)
        try phone.commit()
        recipe.title = "Carrot cake"
        tablet.context.insert(recipe)
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
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        recipe.servings = 3
        phone.context.insert(recipe)
        try await phone.context.save()
        recipe.servings = 1
        recipe.title = "Green salad"
        tablet.context.insert(recipe)
        try await tablet.context.save()

        let result = try #require(try await tablet.recipes().first)
        #expect(result.title == "Salad")
        #expect(result.servings == 3)
        #expect(try tablet.container.defaultStorage.store.pendingChanges().isEmpty)
    }

    @Test func listsMergeItemByItem() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        let first = SyncStep(text: "First")
        let second = SyncStep(text: "Second")
        var recipe = SyncRecipe(title: "Bread", steps: [first, second])
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        var other = recipe
        recipe.steps.append(SyncStep(text: "Bake"))
        phone.context.insert(recipe)
        other.steps.insert(SyncStep(text: "Mix"), at: 0)
        tablet.context.insert(other)

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
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        phone.context.delete(recipe)
        try await phone.context.save()
        recipe.title = "Apple tart"
        tablet.context.insert(recipe)
        try await tablet.context.save()   // the server answers with its deletion

        #expect(try await tablet.recipes().isEmpty)
        #expect(try tablet.context.fetch(SyncStep.self).isEmpty)
        #expect(server.count == 0)
    }

    @Test func aLocalDeleteBeatsAServerEdit() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Jam")
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        tablet.context.delete(recipe)
        try tablet.commit()
        recipe.title = "Plum jam"
        phone.context.insert(recipe)
        try await phone.context.save()
        await tablet.download()   // the edit arrives before the delete is sent
        #expect(try await tablet.recipes().isEmpty)

        try await tablet.context.save()
        try await phone.context.refresh()
        #expect(try await phone.recipes().isEmpty)
    }

    @Test func deletesFollowTheMergePolicysChoiceForClashes() async throws {
        // Under `.mergeProperties(otherwise: .localWins)` a local edit outlives a server delete.
        let phone = try Device(server)
        let tablet = try Device(server, mergePolicy: .mergeProperties(otherwise: .localWins))
        var recipe = SyncRecipe(title: "Pie")
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()
        phone.context.delete(recipe)
        try await phone.context.save()
        recipe.title = "Pear pie"
        tablet.context.insert(recipe)
        try await tablet.context.save()
        #expect(try await tablet.recipes().map(\.title) == ["Pear pie"])
        #expect(server.count == 1)

        // Under `.mergeProperties(otherwise: .serverWins)` a server edit undoes a local delete.
        let laptop = try Device(server, mergePolicy: .mergeProperties(otherwise: .serverWins))
        try await laptop.context.refresh()
        laptop.context.delete(recipe)
        try laptop.commit()
        recipe.title = "Pear and fig pie"
        tablet.context.insert(recipe)
        try await tablet.context.save()
        await laptop.download()
        #expect(try await laptop.recipes().map(\.title) == ["Pear and fig pie"])
    }

    // MARK: Arrival order and newer versions

    @Test func linksArrivingBeforeTheirTargetsResolveLater() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let step = SyncStep(text: "Whisk")
        server.put("SyncRecipe", json: #"{"title":"Omelette","steps":["\#(step.id)"]}"#)
        await phone.download()
        var recipe = try #require(try await phone.recipes().first)
        #expect(recipe.steps.isEmpty)

        // Saving the recipe here keeps the link it can't see yet.
        recipe.title = "Cheese omelette"
        phone.context.insert(recipe)
        try phone.commit()
        server.put("SyncStep", id: step.id, json: #"{"text":"Whisk"}"#)
        await phone.download()
        #expect(try await phone.recipes().first?.steps.map(\.text) == ["Whisk"])
    }

    @Test func fieldsFromNewerVersionsAreKeptAndSentBack() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let id = UUID()
        server.put("SyncRecipe", id: id, json: #"{"title":"Curry","spice":{"level":3}}"#)
        await phone.download()
        var recipe = try #require(try await phone.recipes().first)
        recipe.title = "Green curry"
        phone.context.insert(recipe)
        try await phone.context.save()

        #expect(server.value("SyncRecipe", id, "title", as: String.self) == "Green curry")
        #expect(server.value("SyncRecipe", id, "spice", as: [String: Int].self) == ["level": 3])
    }

    @Test func oldPropertyNamesAreReadFromFields() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        server.put("SyncRecipe", json: #"{"title":"Rice","notes":"Rinse first"}"#)
        await phone.download()
        #expect(try await phone.recipes().first?.summary == "Rinse first")
    }

    @Test func recordsThatDontDecodeAreKept() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let id = UUID()
        server.put("SyncRecipe", id: id, json: #"{"title":"Odd","servings":"lots"}"#)
        server.put("Unknown", json: #"{"x":"y"}"#)
        server.put("SyncRecipe", json: #"{"title":"Fine"}"#)
        await phone.download()
        #expect(phone.context.status == .failed(.incompatibleRecord(type: "SyncRecipe", id: id)))
        #expect(try await phone.recipes().map(\.title) == ["Fine"])
        let parked = try phone.container.defaultStorage.store.db.run("SELECT COUNT(*) AS n FROM \"_records_parked\"")
        #expect(parked.first?["n"] == .integer(2))
    }

    @Test func assetsTravelAsFiles() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Photo")
        recipe.photo = Data([1, 2, 3])
        phone.context.insert(recipe)
        try await phone.context.save()
        await phone.transfers()
        try await tablet.context.refresh()
        await tablet.transfers()
        let received = try #require(try await tablet.recipes().first)
        #expect(received.photo == Data([1, 2, 3]))
        #expect(received.$photo.url?.path.hasPrefix(tablet.container.assetsDirectory.path) == true)
        // The JSON holds the file's ID, and the file travels on its own.
        let assetID = try #require(server.value("SyncRecipe", recipe.id, "photo", as: String.self))
        #expect(server.asset(assetID) == Data([1, 2, 3]))
        #expect(received.$photo.url?.lastPathComponent == assetID)

        // An unchanged photo isn't uploaded again.
        var renamed = received
        renamed.title = "Photo again"
        tablet.context.insert(renamed)
        try await tablet.context.save()
        await tablet.transfers()
        #expect(tablet.provider.sentBatches.count == 1)
        #expect(tablet.provider.sentAssets.isEmpty)
        #expect(phone.provider.sentAssets == [assetID])
        #expect(server.value("SyncRecipe", recipe.id, "photo", as: String.self) == assetID)
    }

    @Test func recordsArriveBeforeTheirFiles() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        phone.provider.failsAssetUploads = true
        var recipe = SyncRecipe(title: "Photo")
        recipe.photo = Data([1, 2, 3])
        phone.context.insert(recipe)
        try await phone.context.save()
        await phone.transfers()
        let assetID = try #require(server.value("SyncRecipe", recipe.id, "photo", as: String.self))
        #expect(server.asset(assetID) == nil)

        // The record syncs without its file, whose asset reads nil until it lands.
        try await tablet.context.refresh()
        await tablet.transfers()
        let waiting = try #require(try await tablet.recipes().first)
        #expect(waiting.title == "Photo")
        #expect(waiting.photo == nil)
        #expect(waiting.$photo.url == nil)
        #expect(tablet.context.status == .saved)
        // The fetch sent again, which retried the download, so wait for that to finish too.
        await tablet.transfers()
        #expect(tablet.context.assetProgress == nil)

        // The upload is tried again after the next pass, and the download after the tablet's.
        phone.provider.failsAssetUploads = false
        try await phone.context.refresh()
        await phone.transfers()
        #expect(server.asset(assetID) == Data([1, 2, 3]))
        let changes = tablet.context.changeCount
        try await tablet.context.refresh()
        await tablet.transfers()
        #expect(tablet.context.changeCount > changes)
        let landed = try #require(try await tablet.recipes().first)
        #expect(landed.photo == Data([1, 2, 3]))
        #expect(landed.$photo.url?.lastPathComponent == assetID)
    }

    @Test func assetProgressCountsFiles() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        for title in ["One", "Two"] {
            var recipe = SyncRecipe(title: title)
            recipe.photo = Data(title.utf8)
            phone.context.insert(recipe)
        }
        try await phone.context.save()
        await phone.transfers()
        #expect(phone.provider.sentAssets.count == 2)

        let seen = Seen()
        let context = tablet.context
        tablet.provider.beforeAssetDownload = {
            for _ in 0..<20 { await Task.yield() }
            await seen.add(await MainActor.run { context.assetProgress })
        }
        try await tablet.context.refresh()
        await tablet.transfers()
        #expect(await seen.values == [0, 0.5])
        #expect(tablet.context.assetProgress == nil)
        #expect(try await tablet.recipes().compactMap(\.photo).count == 2)
    }

    // MARK: Status

    @Test func unsyncedChangesCountWhatTheServerLacks() async throws {
        let phone = try Device(server)
        server.isOnline = false
        phone.context.insert(SyncRecipe(title: "Soup"))
        phone.context.insert(SyncRecipe(title: "Stew"))
        try await phone.context.save()
        await phone.settle()
        #expect(phone.context.unsyncedChanges == 2)
        #expect(phone.context.unsavedChanges == 0)

        server.isOnline = true
        try await phone.context.refresh()
        await phone.settle()
        #expect(phone.context.unsyncedChanges == 0)

        // Without a sync provider nothing is waiting to be sent.
        let local = try RecordContainer(for: [SyncRecipe.self], inMemory: true)
        local.mainContext.insert(SyncRecipe(title: "Toast"))
        try await local.mainContext.save()
        #expect(local.mainContext.unsyncedChanges == 0)
    }

    @Test func statusFollowsTheServer() async throws {
        let phone = try Device(server)
        server.isOnline = false
        phone.context.insert(SyncRecipe(title: "Offline"))
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
        phone.context.insert(SyncRecipe(title: "Too much"))
        await #expect(throws: RecordsError.storageFull) { try await phone.context.refresh() }
        await phone.settle()
        #expect(phone.context.status == .failed(.storageFull))

        server.isFull = false
        server.rejectedTypes = ["SyncCook"]
        let cook = SyncCook(name: "Refused")
        phone.context.insert(cook)
        try await phone.context.save()
        await phone.settle()
        #expect(phone.context.status == .failed(.rejected(type: "SyncCook", id: cook.id)))
    }

    @Test func localContainersReportStatusToo() async throws {
        let context = try RecordContainer(inMemory: true).mainContext
        context.autosaveEnabled = false
        #expect(context.status == .saved)
        context.insert(Measurement(value: .nan))
        await #expect(throws: RecordsError.self) { try await context.save() }
        #expect(context.status == .failed(.invalidValue(type: "Measurement", property: "value")))
        context.rollback()
        context.insert(Measurement(value: 1))
        try await context.save()
        #expect(context.status == .saved)
        try await context.refresh()
    }

    // MARK: Accounts and resets

    @Test func signingOutKeepsLocalDataByDefault() async throws {
        let phone = try Device(server)
        phone.context.insert(SyncRecipe(title: "Mine"))
        try await phone.context.save()
        server.withLock { server.account = nil }
        try await phone.context.refresh()
        await phone.settle()
        #expect(phone.context.status == .signedOut)
        #expect(try await phone.recipes().count == 1)

        // Edits while signed out wait for the next account.
        phone.context.insert(SyncRecipe(title: "Later"))
        try await phone.context.save()
        #expect(server.count == 1)
        server.withLock { server.account = "alice" }
        try await phone.context.refresh()
        await phone.settle()
        #expect(server.count == 2)
        #expect(phone.context.status == .saved)
    }

    @Test func signingOutCanDeleteLocalData() async throws {
        let phone = try Device(server, onSignOut: .deleteLocalData)
        phone.context.insert(SyncRecipe(title: "Mine"))
        try await phone.context.save()
        server.withLock { server.account = nil }
        try await phone.context.refresh()
        #expect(try await phone.recipes().isEmpty)
        #expect(server.count == 1)
    }

    @Test func switchingAccountsDeletesTheOldAccountsData() async throws {
        let phone = try Device(server)
        phone.context.insert(SyncRecipe(title: "Alice's"))
        try await phone.context.save()
        server.withLock { server.account = "bob" }
        try await phone.context.refresh()
        #expect(try await phone.recipes().isEmpty)

        // Alice's records come back with her.
        server.withLock { server.account = "alice" }
        try await phone.context.refresh()
        #expect(try await phone.recipes().map(\.title) == ["Alice's"])
    }

    @Test func aServerResetUploadsEverythingAgain() async throws {
        let phone = try Device(server)
        phone.context.insert(SyncRecipe(title: "Keep", steps: [SyncStep(text: "One")]))
        try await phone.context.save()
        server.reset()
        try await phone.context.refresh()
        #expect(server.count == 2)
        #expect(try phone.container.defaultStorage.store.pendingChanges().isEmpty)
    }

    @Test func aFirstSignInUploadsExistingRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let local = try RecordContainer(directory: directory)
            try local.save(SyncRecipe(title: "Before sync"))
        }
        let phone = try Device(server, directory: directory)
        try await phone.context.refresh()
        #expect(server.count == 1)
    }

    @Test func switchingProvidersUploadsEverythingToTheNewServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let phone = try Device(server, directory: directory)
            phone.context.insert(SyncRecipe(title: "Soup"))
            try await phone.context.save()
            #expect(server.count == 1)
        }
        // A bigger server, where the same person has another user ID.
        let bigger = TestServer()
        let moved = try Device(bigger, directory: directory, account: "new-id")
        try await moved.context.refresh()
        #expect(bigger.count == 1)
        #expect(try await moved.recipes().map(\.title) == ["Soup"])
        #expect(moved.context.unsyncedChanges == 0)
    }

    @Test func changesSentBeforeACrashAreSentAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recipe = SyncRecipe(title: "Unacknowledged")
        do {
            let phone = try Device(server, directory: directory)
            phone.provider.dropsAcknowledgements = true
            phone.context.insert(recipe)
            try await phone.context.save()
            #expect(server.count == 1)
            #expect(try phone.container.defaultStorage.store.pendingChanges().count == 1)
        }
        let relaunched = try Device(server, directory: directory)
        try await relaunched.context.refresh()
        #expect(relaunched.provider.sentBatches.first?.map(\.id) == [recipe.id])   // answered with a conflict, then merged
        #expect(try relaunched.container.defaultStorage.store.pendingChanges().isEmpty)
        #expect(try await relaunched.recipes().map(\.title) == ["Unacknowledged"])
    }
}

@MainActor
@Suite struct SyncedOrderTests {
    let server = TestServer()

    @Test func datesCrossToTheMillisecond() async throws {
        let phone = try Device(server)
        let recipe = SyncRecipe(title: "Soup", updated: Date(timeIntervalSince1970: 1_000.123_456))
        phone.context.insert(recipe)
        try await phone.context.save()
        #expect(server.value("SyncRecipe", recipe.id, "updated", as: Double.self)?.rounded() == 1_000_123)

        try await phone.context.refresh()
        #expect(try phone.container.defaultStorage.store.pendingChanges().isEmpty)
    }
}

@MainActor
@Suite struct ZoneSyncTests {
    let server = TestServer()

    @Test func downloadsComeInPages() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        tablet.provider.pageSize = 2
        for index in 0..<5 {
            phone.context.insert(SyncRecipe(title: "Recipe \(index)"))
        }
        try await phone.context.save()
        try await tablet.context.refresh()
        #expect(try await tablet.recipes().count == 5)
    }

    @Test func publicRecordsCarryTheirOwner() async throws {
        server.publicZones = [.default]
        let alice = try Device(server, publicZones: [.default])
        let bob = try Device(server, account: "bob", publicZones: [.default])
        var recipe = SyncRecipe(title: "Shared")
        alice.context.insert(recipe)
        try await alice.context.save()
        #expect(server.record("SyncRecipe", recipe.id)?.owner == "alice")
        #expect(!server.has("SyncRecipe", recipe.id, "_owner"))

        // Everyone sees it, and only its owner can change it.
        try await bob.context.refresh()
        recipe = try #require(try await bob.recipes().first)
        recipe.title = "Bob's now"
        bob.context.insert(recipe)
        try await bob.context.save()
        await bob.settle()
        #expect(bob.context.status == .failed(.rejected(type: "SyncRecipe", id: recipe.id)))
        #expect(server.value("SyncRecipe", recipe.id, "title", as: String.self) == "Shared")

        // Signing out never deletes public records, and they still download.
        let reader = try Device(server, account: .some(nil), publicZones: [.default])
        try await reader.context.refresh()
        #expect(try await reader.recipes().map(\.title) == ["Shared"])
    }

    @Test func localOnlyAndInMemoryZonesNeverSync() async throws {
        let phone = try Device(server)
        phone.context.zone = .localOnly
        phone.context.insert(SyncRecipe(title: "Draft"))
        phone.context.zone = .inMemory
        phone.context.insert(SyncRecipe(title: "Scratch"))
        try await phone.context.refresh()
        #expect(server.count == 0)
        #expect(phone.provider.sentBatches.isEmpty)
    }
}

/// Values a provider hook saw.
private actor Seen {
    private(set) var values: [Double?] = []

    func add(_ value: Double?) {
        values.append(value)
    }
}
