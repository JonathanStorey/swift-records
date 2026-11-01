import Foundation
@testable import SwiftRecords
@testable import SwiftRecordsFileSync
import Testing

/// Devices that sync through one shared folder, as iCloud would copy it between them.
@MainActor
@Suite struct FileSyncTransportTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileSync-\(UUID().uuidString)")

    /// A device that syncs only when asked, or with a watcher, on its own as changes land.
    private func device(watching mode: FileSyncTransport.WatchMode = .none, in folder: URL? = nil) throws -> RecordContainer {
        let transport = FileSyncTransport(location: .other(directory: folder ?? self.folder))
        transport.watchMode = mode
        let engine = PollingSyncEngine(transport: transport, automaticallySync: mode != .none, sendDelay: .milliseconds(10))
        return try RecordContainer(for: [SyncRecipe.self], inMemory: true, syncProvider: engine)
    }

    private func recipes(_ container: RecordContainer) async throws -> [SyncRecipe] {
        try await container.mainContext.fetch(SyncRecipe.self)
    }

    private func recordFile(_ id: UUID) -> URL {
        folder.appendingPathComponent("Records/_default/SyncRecipe/\(id.uuidString.lowercased()).json")
    }

    @Test func recordsTravelAsReadableFiles() async throws {
        let phone = try device()
        let tablet = try device()
        let recipe = SyncRecipe(title: "Soup", servings: 4)
        phone.mainContext.insert(recipe)
        try await phone.mainContext.save()

        let json = try String(contentsOf: recordFile(recipe.id), encoding: .utf8)
        #expect(json.contains(#""title":{"string":"Soup"}"#))
        #expect(json.contains(#""type":"SyncRecipe""#))

        try await tablet.mainContext.refresh()
        #expect(try await recipes(tablet).map(\.title) == ["Soup"])

        // Nothing new downloads twice.
        try await tablet.mainContext.refresh()
        #expect(try await recipes(tablet).count == 1)
    }

    @Test func editsOnBothDevicesMerge() async throws {
        let phone = try device()
        let tablet = try device()
        var recipe = SyncRecipe(title: "Soup")
        phone.mainContext.insert(recipe)
        try await phone.mainContext.save()
        try await tablet.mainContext.refresh()

        recipe.title = "Stew"
        phone.mainContext.insert(recipe)
        try await phone.mainContext.save()
        var other = try #require(try await recipes(tablet).first)
        other.servings = 6
        tablet.mainContext.insert(other)
        // The tablet's copy is out of date, so its upload conflicts and merges with the phone's.
        try await tablet.mainContext.refresh()
        try await phone.mainContext.refresh()
        for container in [phone, tablet] {
            let merged = try #require(try await recipes(container).first)
            #expect(merged.title == "Stew")
            #expect(merged.servings == 6)
        }
    }

    @Test func deletionsTravel() async throws {
        let phone = try device()
        let tablet = try device()
        let recipe = SyncRecipe(title: "Soup")
        phone.mainContext.insert(recipe)
        try await phone.mainContext.save()
        try await tablet.mainContext.refresh()

        phone.mainContext.delete(recipe)
        try await phone.mainContext.save()
        try await tablet.mainContext.refresh()
        #expect(try await recipes(tablet).isEmpty)
        // The file stays behind as a deletion, so a device that syncs later hears of it.
        #expect(FileManager.default.fileExists(atPath: recordFile(recipe.id).path))
        let laptop = try device()
        try await laptop.mainContext.refresh()
        #expect(try await recipes(laptop).isEmpty)
    }

    @Test func assetsTravelAsFiles() async throws {
        let phone = try device()
        let tablet = try device()
        var recipe = SyncRecipe(title: "Photo")
        recipe.photo = Data([1, 2, 3])
        phone.mainContext.insert(recipe)
        try await phone.mainContext.save()
        await phone.initialStorage.sync?.transfers()

        try await tablet.mainContext.refresh()
        await tablet.initialStorage.sync?.transfers()
        let received = try #require(try await recipes(tablet).first)
        #expect(received.photo == Data([1, 2, 3]))
        let name = try #require(received.$photo?.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Records/_default/_assets/\(name)").path))
    }

    @Test func deletingTheFolderDeletesTheZone() async throws {
        let phone = try device()
        let recipe = SyncRecipe(title: "Soup")
        phone.mainContext.insert(recipe)
        try await phone.mainContext.save()
        try await phone.mainContext.refresh()

        try FileManager.default.removeItem(at: folder.appendingPathComponent("Records/_default"))
        // The records leave this device too, and nothing goes back up.
        try await phone.mainContext.refresh()
        try await phone.mainContext.refresh()
        #expect(!FileManager.default.fileExists(atPath: recordFile(recipe.id).path))
        #expect(try await recipes(phone).isEmpty)
    }

    @Test func handWrittenFilesDownload() async throws {
        // Files written by something other than a container, such as a script or another app.
        let zone = folder.appendingPathComponent("Records/_default")
        let id = UUID()
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("SyncRecipe/_ignored"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("_assets"), withIntermediateDirectories: true)
        try Data([4, 5, 6]).write(to: zone.appendingPathComponent("_assets/photo.jpg"))
        let json = """
            {"id":"\(id.uuidString)","record":{"photo":{"asset":"photo.jpg"},"servings":{"int":2},"title":{"string":"Bread"}},\
            "synced":1700000000000,"type":"SyncRecipe","zone":"_default"}
            """
        try Data(json.utf8).write(to: recordFile(id))

        let phone = try device()
        try await phone.mainContext.refresh()
        await phone.initialStorage.sync?.transfers()
        let recipe = try #require(try await recipes(phone).first)
        #expect(recipe.id == id)
        #expect(recipe.title == "Bread")
        #expect(recipe.servings == 2)
        #expect(recipe.photo == Data([4, 5, 6]))

        // An edit is checked against the hand-written file's synced date and accepted.
        var edited = recipe
        edited.servings = 3
        phone.mainContext.insert(edited)
        try await phone.mainContext.save()
        let written = try String(contentsOf: recordFile(id), encoding: .utf8)
        #expect(written.contains(#""servings":{"int":3}"#))
        #expect(!written.contains("1700000000000"))
    }

    // MARK: Pushed changes

    @Test func changesArriveWithoutARefresh() async throws {
        let tablet = try device(watching: .poll(.milliseconds(20)))
        let phone = try device()
        phone.mainContext.insert(SyncRecipe(title: "Soup"))
        try await phone.mainContext.save()
        // The tablet's watcher sees the phone's mark and downloads on its own.
        var titles: [String] = []
        for _ in 0..<250 where titles.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            titles = try await recipes(tablet).map(\.title)
        }
        #expect(titles == ["Soup"])
    }

    @Test func ownChangesArentPushed() async throws {
        let transport = FileSyncTransport(location: .other(directory: folder))
        transport.watchMode = .poll(.milliseconds(10))
        let other = FileSyncTransport(location: .other(directory: folder))
        other.watchMode = .none
        let pushes = try #require(transport.changeNotifications())
        let heard = Heard()
        let listener = Task {
            for await zones in pushes {
                await heard.add(zones)
            }
        }
        defer { listener.cancel() }
        let save = RecordChangeData(id: UUID(), zone: "notes", type: "Note", fields: [:])
        _ = try await transport.modifyRecords(RecordBatch(saves: [save]))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await heard.zones.isEmpty)

        _ = try await other.modifyRecords(RecordBatch(saves: [RecordChangeData(id: UUID(), zone: "notes", type: "Note", fields: [:])]))
        for _ in 0..<250 where await heard.zones.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await heard.zones == [["notes"]])
    }

    #if canImport(Darwin)
    @Test func aWatchedFolderPushesChangesAsTheyLand() async throws {
        let tablet = try device(watching: .folder)
        let phone = try device()
        phone.mainContext.insert(SyncRecipe(title: "Stew"))
        try await phone.mainContext.save()
        var titles: [String] = []
        for _ in 0..<250 where titles.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            titles = try await recipes(tablet).map(\.title)
        }
        #expect(titles == ["Stew"])
    }
    #endif

    @Test func eachLocationWatchesItsOwnWay() {
        #expect(FileSyncTransport(location: .iCloud).watchMode == .metadata)
        #expect(FileSyncTransport(location: .appGroup("group.test")).watchMode == .folder)
        #expect(FileSyncTransport(location: .applicationSupport).watchMode == .none)
        #expect(FileSyncTransport(location: .other(directory: folder)).watchMode == .folder)
    }

    @Test func iCloudPathsMapToZones() {
        let root = URL(fileURLWithPath: "/tmp/Container/Records")
        let zones = FileSyncTransport.zones(forPaths: [
            "/tmp/Container/Records/_default/Recipe/a.json",
            "/tmp/Container/Records/notes/_assets/photo.jpg",
            "/tmp/Container/Records/notes/Note/b.json",
            "/tmp/Container/Other/c.json",
            "/tmp/Container/Records/Bad Name/d.json",
        ], under: root)
        #expect(zones == [.default, "notes"])
    }

    @Test func conflictingVersionsKeepTheLaterSync() {
        func copy(_ milliseconds: Double?) -> RecordChangeData {
            RecordChangeData(
                id: UUID(), zone: .default, type: "Recipe", fields: [:],
                synced: milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
        #expect(FileSyncTransport.newest([copy(1_000), copy(3_000), copy(2_000)]) == 1)
        // A tie keeps the current file, and an unreadable version never wins.
        #expect(FileSyncTransport.newest([copy(3_000), copy(3_000)]) == 0)
        #expect(FileSyncTransport.newest([nil, copy(nil), copy(5)]) == 2)
    }

    // MARK: Sharing

    @Test func aSharedFolderSyncsBetweenPeople() async throws {
        let bobsFolder = folder.appendingPathComponent("bob")
        let alice = try device()
        let bob = try device(in: bobsFolder)
        let family: Zone = "family"
        alice.mainContext.zone = family
        alice.mainContext.insert(SyncRecipe(title: "Soup"))
        try await alice.mainContext.save()
        let share = try await alice.share(family)
        let invitation = try #require(share.url)
        #expect(invitation.path.hasSuffix("/Records/family"))

        let zone = try await bob.acceptShare(invitation)
        #expect(zone.scope == .shared && zone.name == "family")
        #expect(zone.owner == share.participants.first?.id)
        #expect(await bob.sharedZones() == [zone])
        bob.mainContext.zone = zone
        var soup = try #require(try await recipes(bob).first)
        #expect(soup.title == "Soup")
        #expect(try await alice.existingShare(for: family)?.participants.count == 2)

        // Edits go both ways, and the owner's file names the zone as the owner sees it.
        soup.title = "Stew"
        bob.mainContext.insert(soup)
        try await bob.mainContext.save()
        try await alice.mainContext.refresh()
        #expect(try await recipes(alice).map(\.title) == ["Stew"])
        let file = folder.appendingPathComponent("Records/family/SyncRecipe/\(soup.id.uuidString.lowercased()).json")
        #expect(try String(contentsOf: file, encoding: .utf8).contains(#""zone":"family""#))

        // Once Alice stops sharing, Bob's copy goes and his edits can't reach her folder.
        try await alice.stopSharing(family)
        try await bob.mainContext.refresh()
        #expect(try await recipes(bob).isEmpty)
        #expect(await bob.sharedZones().isEmpty)
        #expect(try await recipes(alice).map(\.title) == ["Stew"])
    }

    @Test func leavingASharedFolder() async throws {
        let alice = try device()
        let bob = try device(in: folder.appendingPathComponent("bob"))
        let family: Zone = "family"
        alice.mainContext.zone = family
        alice.mainContext.insert(SyncRecipe(title: "Soup"))
        try await alice.mainContext.save()
        let zone = try await bob.acceptShare(try #require(try await alice.share(family).url))

        try await bob.stopSharing(zone)
        bob.mainContext.zone = zone
        #expect(try await recipes(bob).isEmpty)
        #expect(await bob.sharedZones().isEmpty)
        #expect(try await alice.existingShare(for: family)?.participants.count == 1)
        // A folder that isn't shared can't be joined.
        try await alice.stopSharing(family)
        await #expect(throws: SyncFailure.self) {
            try await bob.acceptShare(folder.appendingPathComponent("Records/family"))
        }
    }

    @Test func locations() async throws {
        let transport = FileSyncTransport(location: .other(directory: folder))
        #expect(transport.directory == folder.appendingPathComponent("Records", isDirectory: true))
        #expect(try await transport.currentUser() == "local")
        #expect(FileSyncTransport().location == .iCloud)
        #if !canImport(Darwin)
        // There is no iCloud on Linux, which reads as signed out.
        #expect(FileSyncTransport().directory == nil)
        #expect(try await FileSyncTransport().currentUser() == nil)
        #endif
    }
}

/// Pushes a listener heard.
private actor Heard {
    private(set) var zones: [[Zone]] = []

    func add(_ push: [Zone]) {
        zones.append(push)
    }
}
