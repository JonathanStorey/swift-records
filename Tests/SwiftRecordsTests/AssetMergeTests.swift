import Foundation
import Testing
@testable import SwiftRecords

/// Keeps the lines both sides added to a text file since the base, ours first. Without a base it says so,
/// so a test can tell a three-way merge from a two-way one.
struct AddedLines: MergeStrategy {
    func merge(base: Data, ours: Data, theirs: Data) -> Data? {
        let original = Self.lines(base)
        let added = Self.lines(ours).filter { !original.contains($0) } + Self.lines(theirs).filter { !original.contains($0) }
        return Data((original + added).joined(separator: "\n").utf8)
    }

    func merge(ours: Data, theirs: Data) -> Data? {
        Data("no base".utf8)
    }

    private static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

@Record
struct Notebook {
    var id = UUID.timestamp
    var title = ""
    @Asset(AddedLines()) var notes: Data?
    @Asset(.keep(.ours)) var cover: Data?
    @Asset var sketch: Data?
}

@MainActor
@Suite struct AssetMergeTests {
    let server = TestServer()

    private func devices() throws -> (Device, Device) {
        (try Device(server, types: [Notebook.self]), try Device(server, types: [Notebook.self]))
    }

    private func notebook(on device: Device) throws -> Notebook {
        try #require(try device.context.fetch(Notebook.self).first)
    }

    @Test func aStrategyMergesTheBytesBothSidesChanged() async throws {
        let (phone, tablet) = try devices()
        var book = Notebook(title: "Ideas")
        book.notes = Data("one\ntwo".utf8)
        phone.context.insert(book)
        try await phone.context.save()
        try await tablet.context.refresh()

        var mine = try notebook(on: phone)
        mine.notes = Data("one\ntwo\nphone".utf8)
        phone.context.insert(mine)
        try phone.commit()
        var theirs = try notebook(on: tablet)
        theirs.notes = Data("one\ntwo\ntablet".utf8)
        tablet.context.insert(theirs)
        try tablet.commit()

        try await phone.context.save()
        // The tablet's send conflicts. It merges against the copy both started from, which it kept.
        try await tablet.context.save()
        try await phone.context.refresh()
        for device in [tablet, phone] {
            let merged = try notebook(on: device)
            #expect(merged.notes == Data("one\ntwo\ntablet\nphone".utf8))
        }
        // The merged file is the record's own and went up with it.
        let id = try #require(server.assetID("Notebook", book.id, "notes"))
        #expect(try notebook(on: tablet).$notes?.lastPathComponent == id)
        #expect(try notebook(on: phone).$notes?.lastPathComponent == id)
    }

    @Test func assetsAddedOnBothSidesMergeWithoutABase() async throws {
        let (phone, tablet) = try devices()
        let book = Notebook(title: "Ideas")
        phone.context.insert(book)
        try await phone.context.save()
        try await tablet.context.refresh()

        var mine = try notebook(on: phone)
        mine.notes = Data("phone".utf8)
        phone.context.insert(mine)
        try phone.commit()
        var theirs = try notebook(on: tablet)
        theirs.notes = Data("tablet".utf8)
        tablet.context.insert(theirs)
        try tablet.commit()

        try await phone.context.save()
        try await tablet.context.save()
        #expect(try notebook(on: tablet).notes == Data("no base".utf8))
    }

    @Test func keepOursHoldsThisDevicesFile() async throws {
        let (phone, tablet) = try devices()
        var book = Notebook(title: "Ideas")
        book.cover = Data("plain".utf8)
        book.sketch = Data("plain".utf8)
        phone.context.insert(book)
        try await phone.context.save()
        try await tablet.context.refresh()

        var mine = try notebook(on: phone)
        mine.cover = Data("red".utf8)
        mine.sketch = Data("red".utf8)
        phone.context.insert(mine)
        try phone.commit()
        var theirs = try notebook(on: tablet)
        theirs.cover = Data("blue".utf8)
        theirs.sketch = Data("blue".utf8)
        tablet.context.insert(theirs)
        try tablet.commit()

        try await phone.context.save()
        try await tablet.context.save()
        try await phone.context.refresh()
        for device in [tablet, phone] {
            let merged = try notebook(on: device)
            // The tablet merged last and kept its cover. A sketch without a strategy keeps the server's.
            #expect(merged.cover == Data("blue".utf8))
            #expect(merged.sketch == Data("red".utf8))
        }
    }

    @Test func baseFilesAreDroppedOnceTheMergeIsSent() async throws {
        let (phone, tablet) = try devices()
        var book = Notebook(title: "Ideas")
        book.notes = Data("one".utf8)
        phone.context.insert(book)
        try await phone.context.save()
        try await tablet.context.refresh()

        var theirs = try notebook(on: tablet)
        theirs.notes = Data("one\ntablet".utf8)
        tablet.context.insert(theirs)
        try tablet.commit()
        let bases = tablet.container.initialStorage.store.assetBasesDirectory
        #expect(try FileManager.default.contentsOfDirectory(atPath: bases.path).count == 1)

        try await tablet.context.save()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: bases.path)) ?? []).isEmpty)
    }
}
