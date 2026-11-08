import Foundation
import SwiftRecords
import SwiftRecordsTesting
import SyncScenarios
import Testing

/// The shared sync scenarios on the in-memory server. The live app in `LiveTests` runs the same ones on
/// CloudKit.
@MainActor
final class InMemoryBackend: SyncBackend {
    let cloud = TestCloud()
    let name = "in-memory"
    let canGoOffline = true
    let attempts = 1
    let pause = Duration.zero

    func makeDevice(_ types: [any Record.Type], zone: Zone) throws -> RecordContainer {
        try RecordContainer(for: types, initialZone: zone, syncingWith: cloud)
    }

    func freshZone() throws -> Zone {
        try Zone("scenario-\(UUID().uuidString.prefix(8).lowercased())")
    }

    func setOnline(_ online: Bool) {
        cloud.isOnline = online
    }

    func cleanUp(_ zone: Zone) async {}
}

@MainActor
@Suite struct ScenarioTests {
    @Test(arguments: SyncScenarios.all.map(\.name))
    func scenario(_ name: String) async throws {
        let scenario = try #require(SyncScenarios.named(name))
        try await scenario.run(on: InMemoryBackend())
    }

    @Test func aTestCloudSyncsTwoContainers() async throws {
        let cloud = TestCloud()
        let phone = try RecordContainer(for: [SyncRecipe.self], syncingWith: cloud)
        let laptop = try RecordContainer(for: [SyncRecipe.self], syncingWith: cloud)
        phone.mainContext.insert(SyncRecipe(title: "Soup"))
        try await phone.mainContext.save()
        #expect(cloud.recordCount == 1)

        try await laptop.mainContext.refresh()
        #expect(try laptop.mainContext.fetch(SyncRecipe.self).map(\.title) == ["Soup"])

        cloud.isOnline = false
        laptop.mainContext.insert(SyncRecipe(title: "Stew"))
        try await laptop.mainContext.save()
        #expect(laptop.mainContext.status == .offline)
        cloud.isOnline = true
        try await laptop.mainContext.refresh()
        #expect(laptop.mainContext.status == .saved)
        #expect(cloud.recordCount == 2)
    }
}

@MainActor
@Suite struct SyncBenchmarkTests {
    /// The live app times these on CloudKit. Here they only have to finish.
    @Test func theBenchmarksRunOnTheInMemoryServer() async throws {
        let results = try await SyncBenchmarks.run(on: InMemoryBackend(), records: 50)
        #expect(results.count == 5)
        #expect(results.allSatisfy { $0.records > 0 })
    }
}
