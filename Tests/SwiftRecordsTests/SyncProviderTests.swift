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
            steps: [SyncStep(text: "Chop"), SyncStep(text: "Simmer")], cook: SyncCook(name: "Ana")
        )
        phone.context.insert(recipe)
        try await phone.context.save()
        #expect(server.count == 4)

        // The JSON reads like the record: plain values, dates in milliseconds, relationships as IDs.
        #expect(server.value("SyncRecipe", recipe.id, "title") == .string("Soup"))
        #expect(server.value("SyncRecipe", recipe.id, "servings") == .int(4))
        #expect(server.value("SyncRecipe", recipe.id, "updated") == .date(Date(timeIntervalSince1970: 1_000)))
        #expect(server.value("SyncRecipe", recipe.id, "steps") == .strings(recipe.steps.map(\.id.uuidString)))
        #expect(server.value("SyncRecipe", recipe.id, "cook") == .strings([recipe.cook!.id.uuidString]))
        #expect(server.value("SyncRecipe", recipe.id, "tags") == .strings(["winter"]))
        #expect(server.value("SyncStep", recipe.steps[0].id, "recipe") == .reference(recipe.id, action: .deleteSelf))
        #expect(!server.has("SyncStep", recipe.steps[0].id, "recipes"))
        #expect(server.record("SyncRecipe", recipe.id)?.tag != nil)

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

    @Test func aClashWithoutEditDatesKeepsTheServersCopy() async throws {
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
        try tablet.commit()   // the later edit, but the type has no @Timestamp(.modified) to say so

        try await phone.context.save()
        try await tablet.context.save()
        try await phone.context.refresh()
        #expect(try await phone.recipes().map(\.title) == ["Lemon cake"])
        #expect(try await tablet.recipes().map(\.title) == ["Lemon cake"])
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

    @Test func movesMadeOnTwoDevicesBothApply() async throws {
        let phone = try Device(server)
        let tablet = try Device(server)
        let steps = ["One", "Two", "Three", "Four", "Five"].map { SyncStep(text: $0) }
        var recipe = SyncRecipe(title: "Stew", steps: steps)
        phone.context.insert(recipe)
        try await phone.context.save()
        try await tablet.context.refresh()

        var other = recipe
        recipe.steps.append(recipe.steps.remove(at: 1))
        phone.context.insert(recipe)
        other.steps.insert(other.steps.remove(at: 4), at: 0)
        tablet.context.insert(other)

        try await phone.context.save()
        try await tablet.context.save()
        try await phone.context.refresh()
        try await tablet.context.refresh()
        for device in [phone, tablet] {
            #expect(try await device.recipes().first?.steps.map(\.text) == ["Five", "One", "Three", "Four", "Two"])
        }
    }

    @Test func listMergeRules() {
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())
        // A removal on either side applies, and each side's insertion keeps its neighbor.
        #expect(SyncMerge.mergeList(local: [a, d, c], server: [a, b, e], base: [a, b, c], preferLocal: false) == [a, d, e])
        // A move made on one side only wins, and an insertion follows its neighbor.
        #expect(SyncMerge.mergeList(local: [c, a, b], server: [a, b, c, d], base: [a, b, c], preferLocal: false) == [c, d, a, b])
        // Moves on both sides apply: b went to the end on one, e to the front on the other.
        #expect(SyncMerge.mergeList(local: [a, c, d, e, b], server: [e, a, b, c, d], base: [a, b, c, d, e], preferLocal: false) == [e, a, c, d, b])
        #expect(SyncMerge.mergeList(local: [a, c, d, e, b], server: [e, a, b, c, d], base: [a, b, c, d, e], preferLocal: true) == [e, a, c, d, b])
        // An item both sides moved takes the preferred side's place.
        #expect(SyncMerge.mergeList(local: [b, c, a], server: [b, a, c], base: [a, b, c], preferLocal: false) == [b, a, c])
        #expect(SyncMerge.mergeList(local: [b, c, a], server: [b, a, c], base: [a, b, c], preferLocal: true) == [b, c, a])
        // A move whose neighbor was removed on the other side follows the nearest item still there.
        #expect(SyncMerge.mergeList(local: [b, c, d, a], server: [a, b, c], base: [a, b, c, d], preferLocal: false) == [b, c, a])
        // A move and an insertion from different sides.
        #expect(SyncMerge.mergeList(local: [c, a, b], server: [a, d, b, c], base: [a, b, c], preferLocal: false) == [c, a, d, b])
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

    // MARK: Arrival order and newer versions

    @Test func linksArrivingBeforeTheirTargetsResolveLater() async throws {
        let phone = try Device(server)
        _ = try await phone.recipes()
        let step = SyncStep(text: "Whisk")
        server.put("SyncRecipe", fields: ["title": .string("Omelette"), "steps": .strings([step.id.uuidString])])
        await phone.download()
        var recipe = try #require(try await phone.recipes().first)
        #expect(recipe.steps.isEmpty)

        // Saving the recipe here keeps the link it can't see yet.
        recipe.title = "Cheese omelette"
        phone.context.insert(recipe)
        try phone.commit()
        server.put("SyncStep", id: step.id, fields: ["text": .string("Whisk")])
        await phone.download()
        #expect(try await phone.recipes().first?.steps.map(\.text) == ["Whisk"])
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

    @Test func aServerResetUploadsEverythingAgain() async throws {
        let phone = try Device(server)
        phone.context.insert(SyncRecipe(title: "Keep", steps: [SyncStep(text: "One")]))
        try await phone.context.save()
        server.reset()
        try await phone.context.refresh()
        #expect(server.count == 2)
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

    @Test func publicRecordsCarryTheirOwner() async throws {
        server.publicZones = [.default]
        let alice = try Device(server)
        let bob = try Device(server, account: "bob")
        var recipe = SyncRecipe(title: "Shared")
        alice.context.insert(recipe)
        try await alice.context.save()
        #expect(server.creator("SyncRecipe", recipe.id) == "alice")
        #expect(!server.has("SyncRecipe", recipe.id, "_owner"))

        // Everyone sees it, and only its owner can change it.
        try await bob.context.refresh()
        recipe = try #require(try await bob.recipes().first)
        recipe.title = "Bob's now"
        bob.context.insert(recipe)
        try await bob.context.save()
        await bob.settle()
        #expect(bob.context.status == .failed(.rejected(type: "SyncRecipe", id: recipe.id)))
        #expect(server.value("SyncRecipe", recipe.id, "title") == .string("Shared"))

        // Signing out never deletes public records, and they still download.
        let reader = try Device(server, account: .some(nil))
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
