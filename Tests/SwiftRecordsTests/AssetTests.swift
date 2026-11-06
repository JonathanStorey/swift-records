import Foundation
import Identification
@testable import SwiftRecords
import Testing

@Record
struct Photo {
    var id = UUID.timestamp
    var caption = ""
    @Asset var image: Data? = nil
    @Reference(from: Album.self, action: .deleteSelf) var album: Album.ID?
}

@Record
struct Album {
    var id = UUID.timestamp
    @Reference(to: \Photo.album) var photos: [Photo] = []
}

@Suite struct AssetTests {
    let container = try! RecordContainer(inMemory: true)

    /// The asset files themselves, without the folders of stable paths records read them through.
    private func files() -> [String] {
        let directory = container.assetsDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }.sorted()
    }

    @Test func storesDataAsAFile() throws {
        let photo = Photo(image: Data("pixels".utf8))
        #expect(photo.$image == nil)
        try container.save(photo)

        let fetched = try #require(try container.fetch(Photo.self, id: photo.id))
        let url = try #require(fetched.$image)
        // Each record property reads its asset through a path of its own.
        let expected = container.assetsDirectory.appendingPathComponent("Photo/\(photo.id.uuidString)/image.asset")
        #expect(url.standardizedFileURL.path == expected.standardizedFileURL.path)
        #expect(try Data(contentsOf: url) == Data("pixels".utf8))
        #expect(fetched.image == Data("pixels".utf8))
    }

    @Test func loadsLazilyAndCaches() throws {
        try container.save(Photo(image: Data("lazy".utf8)))
        let fetched = try #require(try container.fetch(Photo.self).first)
        let url = try #require(fetched.$image)

        // Nothing is read until the property is used, and then the bytes stay with the record.
        try Data("changed on disk".utf8).write(to: url)
        #expect(fetched.image == Data("changed on disk".utf8))
        try FileManager.default.removeItem(at: url)
        #expect(fetched.image == Data("changed on disk".utf8))
    }

    @Test func copiesFromAFile() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("asset-\(UUID()).png")
        try Data("from disk".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var photo = Photo()
        photo.$image = source
        try container.save(photo)

        let url = try #require(try container.fetch(Photo.self, id: photo.id)?.$image)
        #expect(url != source)
        #expect(url.pathExtension == "png")
        #expect(try String(contentsOf: url, encoding: .utf8) == "from disk")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func nilAssetDecodesAsNil() throws {
        let photo = Photo(caption: "none")
        try container.save(photo)
        let fetched = try #require(try container.fetch(Photo.self, id: photo.id))
        #expect(fetched.image == nil)
        #expect(fetched.$image == nil)
    }

    @Test func resavingKeepsOneFile() throws {
        var photo = Photo(image: Data("a".utf8))
        try container.save(photo)
        photo.caption = "edited"
        try container.save(photo)
        try container.save(try #require(try container.fetch(Photo.self, id: photo.id)))
        #expect(files().count == 1)
    }

    @Test func replacingOrClearingRemovesTheOldFile() throws {
        var photo = Photo(image: Data("old".utf8))
        try container.save(photo)
        let old = try #require(try container.fetch(Photo.self, id: photo.id)?.$image)

        photo.image = Data("new".utf8)
        try container.save(photo)
        // The property's path stays the same and holds the new bytes.
        #expect(try container.fetch(Photo.self, id: photo.id)?.$image == old)
        #expect(try Data(contentsOf: old) == Data("new".utf8))
        #expect(files().count == 1)

        photo.image = nil
        try container.save(photo)
        #expect(files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try container.fetch(Photo.self, id: photo.id)?.image == nil)
    }

    @Test func deletingRemovesFilesThroughCascades() throws {
        let album = Album(photos: [Photo(image: Data("1".utf8)), Photo(image: Data("2".utf8))])
        try container.save(album)
        #expect(files().count == 2)

        try container.delete(album)
        #expect(files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: container.assetsDirectory.appendingPathComponent("Photo/\(album.photos[0].id.uuidString)").path))
    }

    @Test func sharedAssetsGetTheirOwnCopy() throws {
        let first = Photo(image: Data("shared".utf8))
        try container.save(first)
        let fetched = try #require(try container.fetch(Photo.self, id: first.id))

        var second = Photo()
        second.$image = fetched.$image
        try container.save(second)
        #expect(files().count == 2)

        try container.delete(first)
        #expect(try container.fetch(Photo.self, id: second.id)?.image == Data("shared".utf8))
    }

    @Test func rollbackRemovesNewFilesAndKeepsReleasedOnes() throws {
        var photo = Photo(image: Data("kept".utf8))
        try container.save(photo)
        let kept = files()

        struct Abort: Error {}
        photo.image = Data("discarded".utf8)
        #expect(throws: Abort.self) {
            try container.transaction {
                try container.save(photo)
                throw Abort()
            }
        }
        #expect(files() == kept)
        #expect(try container.fetch(Photo.self, id: photo.id)?.image == Data("kept".utf8))
    }

    @Test func encodesAsPlainDataOutsideAContainer() throws {
        try container.save(Photo(caption: "A", image: Data("bytes".utf8)))
        let fetched = try #require(try container.fetch(Photo.self).first)

        let json = try JSONEncoder().encode(fetched)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["image"] as? String == Data("bytes".utf8).base64EncodedString())

        let decoded = try JSONDecoder().decode(Photo.self, from: json)
        #expect(decoded.image == Data("bytes".utf8))

        // An empty asset is left out, and a missing key decodes as nil.
        let empty = try JSONEncoder().encode(Photo(caption: "B"))
        #expect(String(decoding: empty, as: UTF8.self).contains("image") == false)
        #expect(try JSONDecoder().decode(Photo.self, from: empty).image == nil)
    }

    @Test func zoneFilesSitBesideTheDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let photo = Photo(image: Data("x".utf8))
        do {
            let container = try RecordContainer(location: .directory(directory))
            #expect(container.assetsDirectory.lastPathComponent == "_default.assets")
            try container.save(photo)
        }
        let reopened = try RecordContainer(location: .directory(directory))
        #expect(try reopened.fetch(Photo.self, id: photo.id)?.image == Data("x".utf8))
    }

    @Test func inMemoryAssetsAreRemovedWithTheContainer() throws {
        var directory: URL?
        do {
            let container = try RecordContainer(inMemory: true)
            try container.save(Photo(image: Data("temp".utf8)))
            directory = container.assetsDirectory
            #expect(FileManager.default.fileExists(atPath: directory!.path))
        }
        #expect(!FileManager.default.fileExists(atPath: directory!.path))
    }
}
