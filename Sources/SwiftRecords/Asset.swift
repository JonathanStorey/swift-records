import Foundation

/// A file stored beside the database instead of inside it, like `CKAsset`. Use it for photos, audio
/// and anything else too large to load with every fetch. The property must be optional:
///
/// ```swift
/// @Record
/// struct Photo {
///     var id = UUID()
///     var image: Asset?
/// }
///
/// try container.save(Photo(image: Asset(data: jpeg, fileExtension: "jpg")))
/// let url = try container.fetch(Photo.self).first?.image?.fileURL
/// ```
///
/// Files live in a folder named after the database file, such as `Records/default.assets/`. An asset
/// is immutable: to change the file, assign a new `Asset`. The old file is removed when the record is
/// saved, and a record's files are removed when it is deleted.
public struct Asset: Hashable, Sendable, Codable {
    enum Source: Sendable {
        case data(Data)
        case file(URL)
    }

    /// The file's name in the assets folder. Unique for each asset.
    public let name: String

    /// The stored file. `nil` until the asset has been saved and fetched back.
    public let fileURL: URL?

    let source: Source?

    /// An asset holding `data`, written to disk when its record is saved.
    public init(data: Data, fileExtension: String = "") {
        name = Self.makeName(fileExtension: fileExtension)
        fileURL = nil
        source = .data(data)
    }

    /// An asset copied from the file at `url` when its record is saved. The file is not moved.
    public init(contentsOf url: URL) {
        name = Self.makeName(fileExtension: url.pathExtension)
        fileURL = nil
        source = .file(url)
    }

    init(name: String, fileURL: URL?) {
        self.name = name
        self.fileURL = fileURL
        source = nil
    }

    /// The file's contents.
    public func data() throws -> Data {
        switch source {
        case .data(let data): return data
        case .file(let url): return try Data(contentsOf: url)
        case nil:
            guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
            return try Data(contentsOf: fileURL)
        }
    }

    var fileExtension: String { (name as NSString).pathExtension }

    static func makeName(fileExtension: String) -> String {
        fileExtension.isEmpty ? UUID().uuidString : UUID().uuidString + "." + fileExtension
    }

    // An asset's identity is its name, because the file behind a name never changes.
    public static func == (lhs: Asset, rhs: Asset) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    // Outside a container an asset encodes as its name only.
    public init(from decoder: Decoder) throws {
        self.init(name: try decoder.singleValueContainer().decode(String.self), fileURL: nil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}
