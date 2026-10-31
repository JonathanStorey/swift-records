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
    @Reference(to: \SyncStep.recipe) var steps: [SyncStep] = []
    @Reference(to: SyncCook.self) var cooks: [SyncCook] = []
    @Asset var photo: Data?
}

@Record
struct SyncStep {
    var id = UUID.ordered()
    var text: String
    @Reference(from: SyncRecipe.self, action: .deleteSelf) var recipe: SyncRecipe.ID?
}

@Record
struct SyncCook {
    var id = UUID.ordered()
    var name: String
    @Reference(to: \SyncRecipe.cooks) var recipeIDs: Set<SyncRecipe.ID>
}

/// One device: an in-memory container syncing through its own provider.
@MainActor
struct Device {
    let provider: TestProvider
    let container: RecordContainer
    var context: RecordContext { container.mainContext }

    init(_ server: TestServer, directory: URL? = nil, account: String?? = nil) throws {
        let provider = TestProvider(server: server, account: account)
        self.provider = provider
        container = try RecordContainer(
            for: [SyncRecipe.self], directory: directory, inMemory: directory == nil, syncProvider: provider
        )
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
        await container.initialStorage.sync?.download()
        await settle()
    }

    /// Waits for the background asset transfers, then lets their progress reach the context.
    func transfers() async {
        await container.initialStorage.sync?.transfers()
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
            steps: [SyncStep(text: "Chop"), SyncStep(text: "Simmer")], cooks: [SyncCook(name: "Ana")]
        )
        phone.context.insert(recipe)
        try await phone.context.save()
        // The recipe, two steps, the cook and the link between the recipe and the cook.
        #expect(server.count == 5)

        // The JSON reads like the record: plain values, dates in milliseconds, and pointers as references.
        #expect(server.value("SyncRecipe", recipe.id, "title") == .string("Soup"))
        #expect(server.value("SyncRecipe", recipe.id, "servings") == .int(4))
        #expect(server.value("SyncRecipe", recipe.id, "updated") == .date(Date(timeIntervalSince1970: 1_000)))
        #expect(!server.has("SyncRecipe", recipe.id, "steps"))
        #expect(!server.has("SyncRecipe", recipe.id, "cooks"))
        #expect(server.value("SyncRecipe", recipe.id, "tags") == .strings(["winter"]))
        #expect(server.value("SyncStep", recipe.steps[0].id, "recipe") == .reference(recipe.id, action: .deleteSelf))
        #expect(server.record("SyncRecipe", recipe.id)?.tag != nil)

        try await tablet.context.refresh()
        let received = try #require(try await tablet.recipes().first)
        #expect(received.id == recipe.id)
        #expect(received.title == "Soup")
        #expect(received.servings == 4)
        #expect(received.tags == ["winter"])
        #expect(received.updated == recipe.updated)
        #expect(received.steps.map(\.text) == ["Chop", "Simmer"])
        #expect(received.cooks.map(\.name) == ["Ana"])
        // The other side of a many-to-many reads the same links.
        #expect(try tablet.context.fetch(SyncCook.self).map(\.recipeIDs) == [[recipe.id]])
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
        let stored = try tablet.container.initialStorage.fetch(SyncRecipe.self)
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

    @Test func anUploadOfAnySizeFinishesInOnePass() async throws {
        let phone = try Device(server)
        try await phone.container.performBackgroundTask { context in
            try context.insert((0..<4_100).map { SyncCook(name: "Cook \($0)") })
        }
        try await phone.context.save()
        #expect(server.count == 4_100)
        #expect(phone.provider.sentBatches.count == 21)
        #expect(try phone.container.initialStorage.store.pendingChanges().isEmpty)
    }

    @Test func ownUploadsComingBackChangeNothing() async throws {
        let phone = try Device(server)
        phone.context.insert(SyncRecipe(title: "Pie", steps: [SyncStep(text: "Bake")]))
        try await phone.context.save()
        let store = phone.container.initialStorage.store
        let token = try store.changeToken
        try await phone.context.refresh()
        #expect(try store.changeToken == token)
    }

    @Test func serverChangesAreNotSentBack() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        phone.context.insert(SyncRecipe(title: "Pie"))
        try await phone.context.save()
        try await tablet.context.refresh()
        try await tablet.context.refresh()
        #expect(tablet.provider.sentBatches.isEmpty)
        #expect(try tablet.container.initialStorage.store.pendingChanges().isEmpty)
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

    @Test func aConflictWithoutEditDatesKeepsTheServersCopy() async throws {
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
        try tablet.commit()   // the later edit, but the type has no @Timestamped(.modified) to say so

        try await phone.context.save()
        try await tablet.context.save()
        try await phone.context.refresh()
        #expect(try await phone.recipes().map(\.title) == ["Lemon cake"])
        #expect(try await tablet.recipes().map(\.title) == ["Lemon cake"])
    }

    @Test func childrenAddedOnTwoDevicesBothArrive() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Bread", steps: [SyncStep(text: "First"), SyncStep(text: "Second")])
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        // Each device adds a step. Each new step is a record of its own, so there's nothing to merge.
        var other = recipe
        recipe.steps.append(SyncStep(text: "Bake"))
        phone.context.insert(recipe)
        other.steps.append(SyncStep(text: "Cool"))
        tablet.context.insert(other)

        try await phone.context.save()
        try await tablet.context.save()
        try await phone.context.refresh()
        try await tablet.context.refresh()
        for device in [phone, tablet] {
            #expect(try await device.recipes().first?.steps.map(\.text) == ["First", "Second", "Bake", "Cool"])
        }
    }

    @Test func savingAnOlderCopyKeepsWhatArrivedSince() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Bread", steps: [SyncStep(text: "First"), SyncStep(text: "Second")], cooks: [SyncCook(name: "Ana")])
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()
        // An edit sheet holds this copy while the phone's changes arrive.
        var draft = try #require(try await tablet.recipes().first)

        recipe.steps.append(SyncStep(text: "Bake"))
        recipe.cooks.append(SyncCook(name: "Ben"))
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        // Only what the draft itself took out is removed.
        draft.title = "Rye"
        draft.steps.removeFirst()
        tablet.context.insert(draft)
        try await tablet.context.save()
        try await phone.context.refresh()
        for device in [phone, tablet] {
            let saved = try #require(try await device.recipes().first)
            #expect(saved.title == "Rye")
            #expect(saved.steps.map(\.text) == ["Second", "Bake"])
            #expect(saved.cooks.map(\.name) == ["Ana", "Ben"])
        }
    }

    @Test func linksMadeOnTwoDevicesBothArrive() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        let ana = SyncCook(name: "Ana")
        var recipe = SyncRecipe(title: "Stew")
        phone.context.insert(recipe)
        phone.context.insert(ana)
        try await phone.context.save()
        try await tablet.context.refresh()

        // Both devices link Ana, and the tablet links Ben too.
        var other = recipe
        recipe.cooks = [ana]
        phone.context.insert(recipe)
        other.cooks = [ana, SyncCook(name: "Ben")]
        tablet.context.insert(other)

        try await phone.context.save()
        try await tablet.context.save()
        try await phone.context.refresh()
        try await tablet.context.refresh()
        for device in [phone, tablet] {
            #expect(try await device.recipes().first?.cooks.map(\.name) == ["Ana", "Ben"])
        }
        // The same pair made on two devices is one record, since its ID comes from the pair.
        #expect(server.records("RecordLink").count == 2)
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

    // MARK: Arrival order and newer versions

    @Test func childrenArrivingBeforeTheirParentResolveLater() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let recipeID = UUID.ordered()
        server.put("SyncStep", fields: ["text": .string("Whisk"), "recipe": .reference(recipeID, action: .deleteSelf)])
        await phone.download()
        #expect(try phone.context.fetch(SyncStep.self).map(\.recipe) == [recipeID])

        server.put("SyncRecipe", id: recipeID, fields: ["title": .string("Omelette")])
        await phone.download()
        #expect(try await phone.recipes().first?.steps.map(\.text) == ["Whisk"])
    }

    @Test func linksArrivingBeforeTheirTargetsResolveLater() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let recipeID = UUID.ordered()
        let cook = SyncCook(name: "Ana")
        server.put("SyncRecipe", id: recipeID, fields: ["title": .string("Omelette")])
        server.put("RecordLink", id: _RecordLink.id(relation: "SyncRecipe.cooks", from: recipeID, to: cook.id), fields: [
            "relation": .string("SyncRecipe.cooks"), "from": .reference(recipeID, action: .deleteSelf),
            "to": .reference(cook.id, action: .deleteSelf), "created": .date(Date()),
        ])
        await phone.download()
        var recipe = try #require(try await phone.recipes().first)
        #expect(recipe.cooks.isEmpty)

        // Saving the recipe here keeps the link it can't see yet.
        recipe.title = "Cheese omelette"
        phone.context.insert(recipe)
        try phone.commit()
        server.put("SyncCook", id: cook.id, fields: ["name": .string("Ana")])
        await phone.download()
        #expect(try await phone.recipes().first?.cooks.map(\.name) == ["Ana"])
    }

    @Test func fieldsFromNewerVersionsAreKeptAndSentBack() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let id = UUID()
        server.put("SyncRecipe", id: id, fields: ["title": .string("Curry"), "spice": .bytes(Data(#"{"level":3}"#.utf8))])
        await phone.download()
        var recipe = try #require(try await phone.recipes().first)
        recipe.title = "Green curry"
        phone.context.insert(recipe)
        try await phone.context.save()

        #expect(server.value("SyncRecipe", id, "title") == .string("Green curry"))
        #expect(server.value("SyncRecipe", id, "spice") == .bytes(Data(#"{"level":3}"#.utf8)))
    }

    @Test func oldPropertyNamesAreReadFromFields() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        server.put("SyncRecipe", fields: ["title": .string("Rice"), "notes": .string("Rinse first")])
        await phone.download()
        #expect(try await phone.recipes().first?.summary == "Rinse first")
    }

    @Test func recordsThatDontDecodeAreKept() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let id = UUID()
        server.put("SyncRecipe", id: id, fields: ["title": .string("Odd"), "servings": .string("lots")])
        server.put("Unknown", fields: ["x": .string("y")])
        server.put("SyncRecipe", fields: ["title": .string("Fine")])
        await phone.download()
        #expect(phone.context.status == .failed(.incompatibleRecord(type: "SyncRecipe", id: id)))
        #expect(try await phone.recipes().map(\.title) == ["Fine"])
        let parked = try phone.container.initialStorage.store.db.run("SELECT COUNT(*) AS n FROM \"_records_meta\" WHERE parked IS NOT NULL")
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
        // The record holds the file's ID, and the file travels on its own.
        let assetID = try #require(server.assetID("SyncRecipe", recipe.id, "photo"))
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
        #expect(server.assetID("SyncRecipe", recipe.id, "photo") == assetID)
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
        let assetID = try #require(server.assetID("SyncRecipe", recipe.id, "photo"))
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

    @Test func unsyncedNamesTheRecordsTheServerLacks() async throws {
        let phone = try Device(server)
        server.isOnline = false
        let soup = SyncRecipe(title: "Soup")
        phone.context.insert(soup)
        // An unsaved edit isn't waiting on the server yet.
        #expect(phone.context.unsynced.isEmpty)
        try await phone.context.save()
        await phone.settle()
        #expect(phone.context.unsynced == [soup.id])

        server.isOnline = true
        try await phone.context.refresh()
        await phone.settle()
        #expect(phone.context.unsynced.isEmpty)
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

    @Test func signingOutKeepsLocalData() async throws {
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

    @Test func anotherAccountAfterASignOutReplacesTheRecords() async throws {
        let phone = try Device(server)
        phone.context.insert(SyncRecipe(title: "Alice's"))
        try await phone.context.save()
        server.withLock { server.account = nil }
        try await phone.context.refresh()
        phone.context.insert(SyncRecipe(title: "Unsent"))
        try await phone.context.save()

        // Bob never sees Alice's records, and none of them reach his account.
        server.withLock { server.account = "bob" }
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

    @Test func aServerThatLostItsDataGetsEverythingAgain() async throws {
        let phone = try Device(server)
        phone.context.insert(SyncRecipe(title: "Keep", steps: [SyncStep(text: "One")]))
        try await phone.context.save()
        try await phone.context.refresh()
        server.reset(reason: .encryptedDataReset)
        try await phone.context.refresh()
        #expect(server.count == 2)
        #expect(try phone.container.initialStorage.store.pendingChanges().isEmpty)
    }

    @Test func dataDeletedFromTheServerLeavesTheDevice() async throws {
        let phone = try Device(server)
        phone.context.insert(SyncRecipe(title: "Gone", steps: [SyncStep(text: "One")]))
        try await phone.context.save()
        try await phone.context.refresh()
        // As when the person deletes the app's data in Settings.
        server.reset(reason: .purged)
        try await phone.context.refresh()
        #expect(try await phone.recipes().isEmpty)
        #expect(server.count == 0)
        #expect(try phone.container.initialStorage.store.pendingChanges().isEmpty)
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
            #expect(try phone.container.initialStorage.store.pendingChanges().count == 1)
        }
        let relaunched = try Device(server, directory: directory)
        try await relaunched.context.refresh()
        #expect(relaunched.provider.sentBatches.first?.map(\.id) == [recipe.id])   // answered with a conflict, then merged
        #expect(try relaunched.container.initialStorage.store.pendingChanges().isEmpty)
        #expect(try await relaunched.recipes().map(\.title) == ["Unacknowledged"])
    }
}

@MainActor
@Suite struct SyncedOrderTests {
    let server = TestServer()

    @Test func tagsComeBackWithTheNextUpload() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Soup")
        phone.context.insert(recipe)
        try await phone.context.save()
        let first = try #require(server.record("SyncRecipe", recipe.id)?.tag)

        // The device that uploaded keeps the tag the server answered with.
        recipe.title = "Stew"
        phone.context.insert(recipe)
        try await phone.context.save()
        #expect(phone.provider.sentBatches.last?.first?.tag == first)

        // Another device keeps the tag that arrived with the download.
        let second = try #require(server.record("SyncRecipe", recipe.id)?.tag)
        try await tablet.context.refresh()
        recipe = try #require(try await tablet.recipes().first)
        recipe.title = "Chili"
        tablet.context.insert(recipe)
        try await tablet.context.save()
        #expect(tablet.provider.sentBatches.last?.first?.tag == second)
        #expect(second != first)
    }

    @Test func serversWithoutTagsOrDatesStillSync() async throws {
        server.tagsRecords = false
        server.datesRecords = false
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Soup")
        phone.context.insert(recipe)
        try await phone.context.save()
        #expect(server.record("SyncRecipe", recipe.id)?.tag == nil)
        try await tablet.context.refresh()
        #expect(try await tablet.recipes().map(\.title) == ["Soup"])

        // With nothing to compare, a save simply overwrites.
        recipe.title = "Stew"
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()
        #expect(try await tablet.recipes().map(\.title) == ["Stew"])
        #expect(try phone.container.initialStorage.store.pendingChanges().isEmpty)
    }

    @Test func aStaleChangeTagIsAConflict() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Soup")
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        recipe.title = "Stew"
        phone.context.insert(recipe)
        try await phone.context.save()
        // The tablet's edit carries the first tag, so the server answers with its newer copy, and the merge goes back.
        var edited = try #require(try await tablet.recipes().first)
        edited.servings = 6
        tablet.context.insert(edited)
        try await tablet.context.save()
        #expect(tablet.provider.sentBatches.count == 2)
        let stored = try #require(server.record("SyncRecipe", recipe.id)?.fields)
        #expect(stored["title"] == .string("Stew") && stored["servings"] == .int(6))
    }

    @Test func datesCrossToTheMillisecond() async throws {
        let phone = try Device(server)
        let recipe = SyncRecipe(title: "Soup", updated: Date(timeIntervalSince1970: 1_000.123_456))
        phone.context.insert(recipe)
        try await phone.context.save()
        #expect(server.value("SyncRecipe", recipe.id, "updated") == .date(Date(timeIntervalSince1970: 1_000.123)))

        try await phone.context.refresh()
        #expect(try phone.container.initialStorage.store.pendingChanges().isEmpty)
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

@MainActor
@Suite struct ResumeTests {
    let server = TestServer()

    @Test func resumingSyncsOnlyAfterABreakAndNeverSaves() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        try await tablet.context.refresh()
        phone.context.insert(SyncRecipe(title: "Soup"))
        try await phone.context.save()
        tablet.context.insert(SyncRecipe(title: "Draft"))

        let left = Date()
        tablet.context.leftAt = left
        tablet.context.resume(now: left.addingTimeInterval(60))
        await tablet.settle()
        #expect(try await tablet.recipes().map(\.title) == ["Draft"])

        tablet.context.resume(now: left.addingTimeInterval(300))
        for _ in 0..<200 where try await tablet.recipes().count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await tablet.recipes().map(\.title).sorted() == ["Draft", "Soup"])
        // The draft stays unsaved, and nothing went up.
        #expect(tablet.context.hasChanges)
        #expect(server.count == 1)
    }
}

@MainActor
@Suite struct PollingEngineTests {
    let server = TestServer()

    @Test func anAutomaticEngineSendsWithoutBeingAsked() async throws {
        let provider = TestProvider(server: server, automaticallySync: true)
        let context = try RecordContainer(for: [SyncRecipe.self], inMemory: true, syncProvider: provider).mainContext
        context.insert(SyncRecipe(title: "Soup"))
        try commit(context)
        for _ in 0..<250 where server.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.count == 1)
    }

    /// Commits without asking for a sync, so only the engine's own schedule sends.
    private func commit(_ context: RecordContext) throws {
        try context.save()
    }

    @Test func aFetchOfOneZoneLeavesTheOthersForLater() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        for zone: Zone in ["pantry", "garden"] {
            phone.context.zone = zone
            phone.context.insert(SyncRecipe(title: zone.name))
            try await phone.context.save()
        }
        tablet.context.zone = "pantry"
        try await tablet.context.refresh()
        #expect(try await tablet.recipes().map(\.title) == ["pantry"])
        // The garden changed in the same database fetch, and still arrives when its turn comes.
        tablet.context.zone = "garden"
        try await tablet.context.refresh()
        #expect(try await tablet.recipes().map(\.title) == ["garden"])
    }
}

@MainActor
@Suite struct FieldLevelSyncTests {
    let server = TestServer()

    @Test func anEditSendsOnlyTheFieldsItChanged() async throws {
        let phone = try Device(server)
        let recipe = SyncRecipe(title: "Soup", servings: 4, updated: Date(timeIntervalSince1970: 1_000))
        phone.context.insert(recipe)
        try await phone.context.save()
        // A new record goes whole.
        let first = try #require(phone.provider.sentBatches.last?.first { $0.id == recipe.id })
        #expect(first.changedKeys == nil)

        var edited = recipe
        edited.title = "Stew"
        edited.updated = nil
        phone.context.insert(edited)
        try await phone.context.save()
        let sent = try #require(phone.provider.sentBatches.last?.first { $0.id == recipe.id })
        #expect(sent.changedKeys == ["title"])
        #expect(sent.clearedKeys == ["updated"])
        #expect(sent.sentFields?.keys.sorted() == ["title"])
        // The whole record still travels, for servers that store whole records.
        #expect(sent.fields?["servings"] == .int(4))
        // The server applied only those fields, and kept the rest.
        #expect(server.value("SyncRecipe", recipe.id, "title") == .string("Stew"))
        #expect(server.value("SyncRecipe", recipe.id, "servings") == .int(4))
        #expect(!server.has("SyncRecipe", recipe.id, "updated"))
    }

    @Test func aPartialDownloadAppliesToTheCopyItBuildsOn() async throws {
        server.sendsPartialChanges = true
        let phone = try Device(server)
        let tablet = try Device(server)
        let recipe = SyncRecipe(title: "Soup", servings: 4)
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        var edited = recipe
        edited.title = "Stew"
        phone.context.insert(edited)
        try await phone.context.save()
        try await tablet.context.refresh()
        let received = try #require(try await tablet.recipes().first)
        #expect(received.title == "Stew")
        #expect(received.servings == 4)
        #expect(server.fetchedRecords == 0)
    }

    @Test func aPartialChangeWithoutItsCopyIsFetchedWhole() async throws {
        server.sendsPartialChanges = true
        let phone = try Device(server)
        let recipe = SyncRecipe(title: "Soup", servings: 4)
        phone.context.insert(recipe)
        try await phone.context.save()
        var edited = recipe
        edited.title = "Stew"
        phone.context.insert(edited)
        try await phone.context.save()

        // The tablet never saw the first copy, so the change alone can't rebuild the record.
        let tablet = try Device(server)
        try await tablet.context.refresh()
        let received = try #require(try await tablet.recipes().first)
        #expect(received.title == "Stew")
        #expect(received.servings == 4)
        #expect(server.fetchedRecords == 1)
        #expect(try tablet.container.initialStorage.sync?.refetch().isEmpty == true)
    }

    @Test func aFailedFetchIsTriedAgain() async throws {
        server.sendsPartialChanges = true
        let phone = try Device(server)
        let recipe = SyncRecipe(title: "Soup", servings: 4)
        phone.context.insert(recipe)
        try await phone.context.save()
        var edited = recipe
        edited.title = "Stew"
        phone.context.insert(edited)
        try await phone.context.save()

        let tablet = try Device(server)
        tablet.provider.failsRecordFetches = true
        try await tablet.context.refresh()
        #expect(try await tablet.recipes().isEmpty)
        #expect(try tablet.container.initialStorage.sync?.refetch().count == 1)

        tablet.provider.failsRecordFetches = false
        try await tablet.context.refresh()
        #expect(try await tablet.recipes().map(\.title) == ["Stew"])
    }

    @Test func aPartialDownloadMergesWithAnUnsentEdit() async throws {
        server.sendsPartialChanges = true
        let phone = try Device(server)
        let tablet = try Device(server)
        let recipe = SyncRecipe(title: "Soup", servings: 4)
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        var local = recipe
        local.servings = 6
        tablet.context.insert(local)
        try tablet.commit()
        var remote = recipe
        remote.title = "Stew"
        phone.context.insert(remote)
        try await phone.context.save()

        await tablet.download()
        let merged = try #require(try await tablet.recipes().first)
        #expect(merged.title == "Stew")
        #expect(merged.servings == 6)
        try await tablet.context.save()
        #expect(server.value("SyncRecipe", recipe.id, "title") == .string("Stew"))
        #expect(server.value("SyncRecipe", recipe.id, "servings") == .int(6))
        #expect(tablet.provider.sentBatches.last?.first { $0.id == recipe.id }?.changedKeys == ["servings"])
    }
}

@MainActor
@Suite struct SharedZoneTests {
    let server = TestServer()
    let family: Zone = "family"
    var shared: Zone { try! Zone("family", sharedBy: "alice") }

    @Test func aSharedZoneSyncsBetweenItsOwnerAndParticipants() async throws {
        server.share(family, of: "alice", with: "bob")
        let alice = try Device(server, account: "alice")
        let bob = try Device(server, account: "bob")
        alice.context.zone = family
        let recipe = SyncRecipe(title: "Soup")
        alice.context.insert(recipe)
        try await alice.context.save()

        bob.context.zone = shared
        try await bob.context.refresh()
        #expect(try await bob.recipes().map(\.title) == ["Soup"])

        var edited = recipe
        edited.title = "Stew"
        bob.context.insert(edited)
        try await bob.context.save()
        try await alice.context.refresh()
        #expect(try await alice.recipes().map(\.title) == ["Stew"])
    }

    @Test func aSharedZoneStaysApartFromAPrivateOneOfTheSameName() async throws {
        server.share(family, of: "alice", with: "bob")
        let alice = try Device(server, account: "alice")
        alice.context.zone = family
        alice.context.insert(SyncRecipe(title: "Alice's soup"))
        try await alice.context.save()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bob = try Device(server, directory: directory, account: "bob")
        bob.context.zone = family
        bob.context.insert(SyncRecipe(title: "Bob's soup"))
        try await bob.context.save()
        bob.context.zone = shared
        try await bob.context.refresh()
        #expect(try await bob.recipes().map(\.title) == ["Alice's soup"])
        bob.context.zone = family
        #expect(try await bob.recipes().map(\.title) == ["Bob's soup"])

        #expect(bob.container.url(for: shared)?.path.hasSuffix("/shared/alice/family.sqlite") == true)
        #expect(FileManager.default.fileExists(atPath: try #require(bob.container.url(for: shared)).path))
    }

    @Test func aZoneNotSharedWithYouIsRefused() async throws {
        let alice = try Device(server, account: "alice")
        alice.context.zone = family
        alice.context.insert(SyncRecipe(title: "Soup"))
        try await alice.context.save()

        let eve = try Device(server, account: "eve")
        eve.context.zone = shared
        eve.context.insert(SyncRecipe(title: "Mine now"))
        await #expect(throws: RecordsError.self) { try await eve.context.refresh() }
        alice.context.zone = family
        try await alice.context.refresh()
        #expect(try await alice.recipes().map(\.title) == ["Soup"])
    }

    @Test func aProviderWithoutTheSharedDatabaseKeepsSharedZonesOnTheDevice() async throws {
        let provider = SilentProvider()
        let container = try RecordContainer(for: [SyncRecipe.self], inMemory: true, syncProvider: provider)
        #expect(try container.storage(for: shared).sync == nil)
        #expect(try container.storage(for: family).sync != nil)
    }

    @Test func zonesEncodeAsBefore() throws {
        #expect(String(decoding: try JSONEncoder().encode(family), as: UTF8.self) == "\"family\"")
        let data = try JSONEncoder().encode(shared)
        #expect(try JSONDecoder().decode(Zone.self, from: data) == shared)
        #expect(shared != family)
        #expect(shared.scope == .shared && family.scope == .private)
        #expect(shared.description == "shared/alice/family")
        #expect(Zone.folderName("Alice") == "x416c696365")
        #expect(throws: RecordsError.self) { try Zone("family", sharedBy: "") }
    }
}

@MainActor
@Suite struct FilesInRecordsTests {
    let server: TestServer = {
        let server = TestServer()
        server.filesTravelWithRecords = true
        return server
    }()

    @Test func filesTravelInsideTheirRecords() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        var recipe = SyncRecipe(title: "Photo")
        recipe.photo = Data([1, 2, 3])
        phone.context.insert(recipe)
        try await phone.context.save()
        let assetID = try #require(server.assetID("SyncRecipe", recipe.id, "photo"))
        // The file went up with the record, not on its own.
        #expect(server.asset(assetID) == Data([1, 2, 3]))
        #expect(phone.provider.sentAssets.isEmpty)
        let sent = try #require(phone.provider.sentBatches.first?.first { $0.id == recipe.id })
        #expect(sent.assetFiles[assetID] != nil)

        // It lands as the record does, with no separate download.
        try await tablet.context.refresh()
        await tablet.settle()
        let received = try #require(try await tablet.recipes().first)
        #expect(received.photo == Data([1, 2, 3]))
        #expect(received.$photo.url?.lastPathComponent == assetID)
        #expect(tablet.context.assetProgress == nil)
    }

    @Test func anUnchangedFileIsntNamedAsChanged() async throws {
        let phone = try Device(server)
        var recipe = SyncRecipe(title: "Photo")
        recipe.photo = Data([1, 2, 3])
        phone.context.insert(recipe)
        try await phone.context.save()
        var renamed = try #require(try await phone.recipes().first)
        renamed.title = "Photo again"
        phone.context.insert(renamed)
        try await phone.context.save()
        let sent = try #require(phone.provider.sentBatches.last?.first { $0.id == recipe.id })
        // CloudKit sets only the changed keys, so the photo's CKAsset doesn't go up again.
        #expect(sent.changedKeys == ["title"])
    }
}
