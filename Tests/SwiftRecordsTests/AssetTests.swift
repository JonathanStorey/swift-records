import Foundation
import SwiftRecords
import Testing

@Record
struct Photo {
    var id = UUID()
    var caption = ""
    var image: Asset?
}

@Record
struct Album {
    var id = UUID()
    var photos: [Photo] = []
}

@Suite struct AssetTests {
    let container = try! RecordContainer(zone: .inMemory)

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: container.assetsDirectory.path)) ?? []).sorted()
    }

    @Test func storesDataAsAFile() throws {
        let photo = Photo(image: Asset(data: Data("pixels".utf8), fileExtension: "jpg"))
        try container.save(photo)

        let fetched = try #require(try container.fetch(Photo.self, id: photo.id))
        let url = try #require(fetched.image?.fileURL)
        #expect(url.pathExtension == "jpg")
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == container.assetsDirectory.standardizedFileURL.path)
        #expect(try Data(contentsOf: url) == Data("pixels".utf8))
        #expect(fetched.image == photo.image)
    }

    @Test func copiesFromAFile() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("asset-\(UUID()).txt")
        try Data("from disk".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let photo = Photo(image: Asset(contentsOf: source))
        try container.save(photo)

        let url = try #require(try container.fetch(Photo.self, id: photo.id)?.image?.fileURL)
        #expect(url != source)
        #expect(try String(contentsOf: url, encoding: .utf8) == "from disk")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func nilAssetDecodesAsNil() throws {
        let photo = Photo(caption: "none")
        try container.save(photo)
        #expect(try container.fetch(Photo.self, id: photo.id)?.image == nil)
    }

    @Test func resavingKeepsOneFile() throws {
        var photo = Photo(image: Asset(data: Data("a".utf8)))
        try container.save(photo)
        photo.caption = "edited"
        try container.save(photo)
        try container.save(try #require(try container.fetch(Photo.self, id: photo.id)))
        #expect(files().count == 1)
    }

    @Test func replacingOrClearingRemovesTheOldFile() throws {
        var photo = Photo(image: Asset(data: Data("old".utf8)))
        try container.save(photo)
        let old = try #require(try container.fetch(Photo.self, id: photo.id)?.image?.fileURL)

        photo.image = Asset(data: Data("new".utf8))
        try container.save(photo)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(files() == [photo.image!.name])

        photo.image = nil
        try container.save(photo)
        #expect(files().isEmpty)
        #expect(try container.fetch(Photo.self, id: photo.id)?.image == nil)
    }

    @Test func deletingRemovesFilesThroughCascades() throws {
        let album = Album(photos: [
            Photo(image: Asset(data: Data("1".utf8))),
            Photo(image: Asset(data: Data("2".utf8))),
        ])
        try container.save(album)
        #expect(files().count == 2)

        try container.delete(album)
        #expect(files().isEmpty)
    }

    @Test func sharedAssetsGetTheirOwnCopy() throws {
        let first = Photo(image: Asset(data: Data("shared".utf8)))
        try container.save(first)
        let fetched = try #require(try container.fetch(Photo.self, id: first.id))

        let second = Photo(image: fetched.image)
        try container.save(second)
        #expect(files().count == 2)

        try container.delete(first)
        let url = try #require(try container.fetch(Photo.self, id: second.id)?.image?.fileURL)
        #expect(try Data(contentsOf: url) == Data("shared".utf8))
    }

    @Test func rollbackRemovesNewFilesAndKeepsReleasedOnes() throws {
        var photo = Photo(image: Asset(data: Data("kept".utf8)))
        try container.save(photo)
        let kept = files()

        struct Abort: Error {}
        photo.image = Asset(data: Data("discarded".utf8))
        #expect(throws: Abort.self) {
            try container.transaction {
                try container.save(photo)
                throw Abort()
            }
        }
        #expect(files() == kept)
        let url = try #require(try container.fetch(Photo.self, id: photo.id)?.image?.fileURL)
        #expect(try Data(contentsOf: url) == Data("kept".utf8))
    }

    @Test func zoneFilesSitBesideTheDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let photo = Photo(image: Asset(data: Data("x".utf8), fileExtension: "png"))
        do {
            let container = try RecordContainer(zone: "library", directory: directory)
            #expect(container.assetsDirectory.lastPathComponent == "library.assets")
            try container.save(photo)
        }
        let reopened = try RecordContainer(zone: "library", directory: directory)
        let url = try #require(try reopened.fetch(Photo.self, id: photo.id)?.image?.fileURL)
        #expect(try Data(contentsOf: url) == Data("x".utf8))
    }

    @Test func inMemoryAssetsAreRemovedWithTheContainer() throws {
        var directory: URL?
        do {
            let container = try RecordContainer(zone: .inMemory)
            try container.save(Photo(image: Asset(data: Data("temp".utf8))))
            directory = container.assetsDirectory
            #expect(FileManager.default.fileExists(atPath: directory!.path))
        }
        #expect(!FileManager.default.fileExists(atPath: directory!.path))
    }
}
