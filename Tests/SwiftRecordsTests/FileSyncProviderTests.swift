import Foundation
@testable import SwiftRecords
import Testing

/// Devices that sync through one shared folder, as iCloud would copy it between them.
@MainActor
@Suite struct FileSyncProviderTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileSync-\(UUID().uuidString)")

    private func device(watchInterval: Duration? = nil) throws -> RecordContainer {
        let provider = FileSyncProvider(location: .other(directory: folder), watchInterval: watchInterval)
        let container = try RecordContainer(for: [SyncRecipe.self], inMemory: true, syncProvider: { _ in provider })
        container.mainContext.autosaveEnabled = false
        return container
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
        #expect(json.contains(#""title":"Soup""#))
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
        await phone.defaultStorage.sync?.transfers()

        try await tablet.mainContext.refresh()
        await tablet.defaultStorage.sync?.transfers()
        let received = try #require(try await recipes(tablet).first)
        #expect(received.photo == Data([1, 2, 3]))
        let name = try #require(received.$photo.url?.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Records/_default/_assets/\(name)").path))
    }

    @Test func deletingTheFolderIsAReset() async throws {
        let phone = try device()
        let recipe = SyncRecipe(title: "Soup")
        phone.mainContext.insert(recipe)
        try await phone.mainContext.save()
        try await phone.mainContext.refresh()

        try FileManager.default.removeItem(at: folder.appendingPathComponent("Records/_default"))
        // The default policy keeps the records here and uploads them again.
        try await phone.mainContext.refresh()
        try await phone.mainContext.refresh()
        #expect(FileManager.default.fileExists(atPath: recordFile(recipe.id).path))
        #expect(try await recipes(phone).map(\.title) == ["Soup"])
    }

    @Test func handWrittenFilesDownload() async throws {
        // Files written by something other than a container, such as a script or another app.
        let zone = folder.appendingPathComponent("Records/_default")
        let id = UUID()
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("SyncRecipe/_ignored"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("_assets"), withIntermediateDirectories: true)
        try Data([4, 5, 6]).write(to: zone.appendingPathComponent("_assets/photo.jpg"))
        let json = """
            {"id":"\(id.uuidString)","record":{"photo":"photo.jpg","servings":2,"title":"Bread"},\
            "synced":1700000000000,"type":"SyncRecipe","zone":"_default"}
            """
        try Data(json.utf8).write(to: recordFile(id))

        let phone = try device()
        try await phone.mainContext.refresh()
        await phone.defaultStorage.sync?.transfers()
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
        #expect(written.contains(#""servings":3"#))
        #expect(!written.contains("1700000000000"))
    }

    // MARK: Pushed changes

    @Test func changesArriveWithoutARefresh() async throws {
        let tablet = try device(watchInterval: .milliseconds(20))
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
        let provider = FileSyncProvider(location: .other(directory: folder), watchInterval: .milliseconds(10))
        let other = FileSyncProvider(location: .other(directory: folder), watchInterval: nil)
        let pushes = try #require(provider.pushedChanges())
        let heard = Heard()
        let listener = Task {
            for await zones in pushes {
                await heard.add(zones)
            }
        }
        defer { listener.cancel() }
        let save = RecordChangeData.save(id: UUID(), zone: "notes", type: "Note", json: Data("{}".utf8), owner: nil, synced: nil)
        _ = try await provider.uploadRecordChanges([save])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await heard.zones.isEmpty)

        _ = try await other.uploadRecordChanges([.save(id: UUID(), zone: "notes", type: "Note", json: Data("{}".utf8), owner: nil, synced: nil)])
        for _ in 0..<250 where await heard.zones.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await heard.zones == [["notes"]])
    }

    @Test func iCloudPathsMapToZones() {
        let root = URL(fileURLWithPath: "/tmp/Container/Records")
        let zones = FileSyncProvider.zones(forPaths: [
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
            .save(
                id: UUID(), zone: .default, type: "Recipe", json: Data("{}".utf8), owner: nil,
                synced: milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
        #expect(FileSyncProvider.newest([copy(1_000), copy(3_000), copy(2_000)]) == 1)
        // A tie keeps the current file, and an unreadable version never wins.
        #expect(FileSyncProvider.newest([copy(3_000), copy(3_000)]) == 0)
        #expect(FileSyncProvider.newest([nil, copy(nil), copy(5)]) == 2)
    }

    @Test func locations() async throws {
        let provider = FileSyncProvider(location: .other(directory: folder))
        #expect(provider.directory == folder.appendingPathComponent("Records", isDirectory: true))
        #expect(try await provider.userID() == "local")
        #expect(FileSyncProvider().location == .iCloud)
        #if !canImport(Darwin)
        // There is no iCloud on Linux, which reads as signed out.
        #expect(FileSyncProvider().directory == nil)
        #expect(try await FileSyncProvider().userID() == nil)
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
