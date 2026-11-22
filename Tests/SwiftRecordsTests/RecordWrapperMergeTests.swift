import Foundation
import Testing
@testable import SwiftRecords
import Versioning

private struct Hits: RawRepresentable, Codable, Equatable, Mergeable {
    var rawValue: Int

    func merging(with theirs: Hits, from base: Hits) throws(MergeConflict) -> Hits {
        try merging(with: theirs, from: base, using: .rawValue(.sum()))
    }
}

private struct Photo: Codable, Identifiable {
    var id: UUID
}

private struct Post: Codable, Equatable, Mergeable {
    var title = "Title"
    @Encrypted var hits = Hits(rawValue: 1)
    var place: Location? = nil
    @References var photos: [RecordID<Photo>] = []
}

private func file(containing text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(text.utf8).write(to: url)
    return url
}

private func location(at seconds: TimeInterval, latitude: Double = 1) -> Location {
    Location(latitude: latitude, longitude: 2, timestamp: Date(timeIntervalSinceReferenceDate: seconds))
}

private let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
private let c = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

/// The id of a photo named `name` in the zone `"Z"`.
private func id(_ name: UUID) -> RecordID<Photo> {
    RecordID(name: name, zone: "Z")
}

@Suite struct RecordWrapperValueTests {
    @Test func anAssetIsItsURL() throws {
        let url = try file(containing: "hello")
        let asset = Asset<Data>(rawValue: url)
        #expect(asset.rawValue == url)
        #expect(asset.projectedValue == url)
        #expect(asset.wrappedValue == Data("hello".utf8))
        #expect(Asset<Data>(rawValue: nil).wrappedValue == nil)
    }

    @Test func anEncryptedValueIsItsValue() {
        let pin = Encrypted(rawValue: 42)
        #expect(pin.rawValue == 42)
        #expect(pin.wrappedValue == 42)
        #expect(pin == Encrypted(wrappedValue: 42))
    }
}

@Suite struct RecordWrapperMergeTests {
    @Test func assetsWithTheSameBytesDoNotConflict() throws {
        let base = Asset<Data>(rawValue: try file(containing: "base"))
        let ours = Asset<Data>(rawValue: try file(containing: "same"))
        let theirs = Asset<Data>(rawValue: try file(containing: "same"))
        #expect(try ours.merging(with: theirs, from: base) == ours)
        #expect(try ours.merging(with: theirs) == ours)
    }

    @Test func anAssetKeepsTheSideThatChangedIt() throws {
        let base = Asset<Data>(rawValue: try file(containing: "base"))
        let copy = Asset<Data>(rawValue: try file(containing: "base"))
        let theirs = Asset<Data>(rawValue: try file(containing: "theirs"))
        #expect(try copy.merging(with: theirs, from: base) == theirs, "A copy of the base's bytes is unchanged.")
        #expect(try theirs.merging(with: copy, from: base) == theirs)
    }

    @Test func differentAssetsConflict() throws {
        let base = Asset<Data>(rawValue: try file(containing: "base"))
        let ours = Asset<Data>(rawValue: try file(containing: "ours"))
        let theirs = Asset<Data>(rawValue: try file(containing: "theirs"))
        #expect(throws: MergeConflict()) { try ours.merging(with: theirs, from: base) }
        #expect(throws: MergeConflict()) { try ours.merging(with: Asset<Data>()) }
    }

    @Test func aMergeableValueMergesTheBytesOfAllThreeFiles() throws {
        let base = Asset(wrappedValue: Drawing(rawValue: Data([1])))
        let ours = Asset(wrappedValue: Drawing(rawValue: Data([1, 2])))
        let theirs = Asset(wrappedValue: Drawing(rawValue: Data([1, 3])))
        let merged = try ours.merging(with: theirs, from: base)
        #expect(merged.wrappedValue == Drawing(rawValue: Data([1, 2, 3])))
        #expect(merged.projectedValue != ours.projectedValue)
    }

    @Test func aValueReadsAndWritesThroughItsBytes() {
        var asset = Asset<Drawing>(wrappedValue: nil)
        asset.wrappedValue = Drawing(rawValue: Data([4]))
        #expect(asset.wrappedValue == Drawing(rawValue: Data([4])))
        #expect(asset.projectedValue.map { try? Data(contentsOf: $0) } == Data([4]))
    }

    @Test func anEncryptedValueMergesByItsOwnMerge() throws {
        let merged = try Encrypted(rawValue: Hits(rawValue: 5)).merging(with: Encrypted(rawValue: Hits(rawValue: 4)), from: Encrypted(rawValue: Hits(rawValue: 3)))
        #expect(merged.rawValue == Hits(rawValue: 6))
    }

    @Test func aLocationKeepsTheLaterMeasurement() throws {
        let base = location(at: 0)
        #expect(try location(at: 20).merging(with: location(at: 10, latitude: 5), from: base) == location(at: 20))
        #expect(try location(at: 10).merging(with: location(at: 20, latitude: 5)) == location(at: 20, latitude: 5))
        #expect(try base.merging(with: location(at: -5, latitude: 5), from: base) == location(at: -5, latitude: 5), "Only theirs changed it.")
        #expect(throws: MergeConflict()) { try location(at: 10).merging(with: location(at: 10, latitude: 5), from: base) }
    }

    @Test func referencesKeepEverySidesAdditions() throws {
        let base = References<Photo>(wrappedValue: [id(a)])
        let ours = References<Photo>(wrappedValue: [id(c), id(a)])
        let theirs = References<Photo>(wrappedValue: [id(a), id(b)], action: .deleteSelf)
        let merged = try ours.merging(with: theirs, from: base)
        #expect(merged.wrappedValue == [id(c), id(a), id(b)])
        #expect(merged.action == .deleteSelf, "Only theirs changed the action.")
        #expect(merged.storage == .field)
        #expect(throws: MergeConflict()) { try ours.merging(with: theirs) }
    }

    @Test func theDefaultMergeUsesEachWrappersMerge() throws {
        let base = Post(hits: Hits(rawValue: 3), place: location(at: 0), photos: [id(a)])
        let ours = Post(title: "Ours", hits: Hits(rawValue: 5), place: location(at: 20), photos: [id(c), id(a)])
        let theirs = Post(hits: Hits(rawValue: 4), place: location(at: 10, latitude: 5), photos: [id(a), id(b)])
        #expect(try ours.merging(with: theirs, from: base) == Post(title: "Ours", hits: Hits(rawValue: 6), place: location(at: 20), photos: [id(c), id(a), id(b)]))
    }
}

/// An append-only drawing: each side's new strokes follow the base's.
private struct Drawing: RawRepresentable, Equatable, Mergeable {
    var rawValue: Data

    func merging(with theirs: Drawing, from base: Drawing) throws(MergeConflict) -> Drawing {
        Drawing(rawValue: rawValue + theirs.rawValue.dropFirst(base.rawValue.count))
    }
}
