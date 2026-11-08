import CrateModels
import Foundation
import SwiftRecordsTesting
import Testing

/// The crate on two devices, syncing through SwiftRecordsTesting's in-memory server.
@MainActor
@Suite struct CrateSyncTests {
    let cloud = TestCloud()

    private func device() throws -> RecordContext {
        try RecordContainer(for: crateTypes, syncingWith: cloud).mainContext
    }

    @Test func theCrateArrivesOnAnotherDevice() async throws {
        let phone = try device()
        let laptop = try device()
        try SampleCrate.insert(into: phone)
        try await phone.save()

        try await laptop.refresh()
        #expect(try laptop.fetch(Album.self).count == 8)
        #expect(try laptop.fetch(Track.self).count == 45)
        let skies = try #require(try laptop.fetch(Album.self).first { $0.title == "Copper Skies" })
        #expect(try laptop.record(Artist.self, for: try #require(skies.artist))?.name == "The Velvet Orchard")
    }

    @Test func aLoanAndAPlayFromTwoDevicesBothArrive() async throws {
        let phone = try device()
        let laptop = try device()
        try SampleCrate.insert(into: phone)
        try await phone.save()
        try await laptop.refresh()

        let loans = try laptop.fetch(Loan.self).count
        let album = try #require(try laptop.fetch(Album.self).first { $0.title == "Copper Skies" })
        let friend = try #require(try laptop.fetch(Friend.self).first)
        laptop.lend(album, to: friend, days: 14)
        try await laptop.save()
        let track = try #require(try phone.fetch(Track.self).first { $0.album == album.id })
        try phone.play(track)
        try await phone.save()

        try await phone.refresh()
        try await laptop.refresh()
        for context in [phone, laptop] {
            #expect(try context.fetch(Loan.self).count == loans + 1)
            #expect(try context.record(Album.self, for: album.id)?.plays == album.plays + 1)
        }
    }

    @Test func savesMadeOfflineAreSentOnceBackOnline() async throws {
        let phone = try device()
        cloud.isOnline = false
        try SampleCrate.insert(into: phone)
        try await phone.save()
        #expect(phone.status == .offline)
        #expect(cloud.recordCount == 0)

        cloud.isOnline = true
        try await phone.refresh()
        #expect(phone.status == .saved)
        #expect(cloud.recordCount > 0)
    }
}
