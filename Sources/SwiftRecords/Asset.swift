import Foundation

/// Stores a `Data?` property as a file beside the database instead of inside it, like `CKAsset`. Use it
/// for photos, audio and anything else too large to load with every fetch.
///
/// ```swift
/// @Record
/// struct Recipe {
///     var id = UUID()
///     @Asset(fileExtension: "jpg") var photo: Data?
/// }
///
/// recipe.photo = jpegData                 // written to disk when the record is saved
/// recipe.$photo = movieURL                // or copied in from a file, without loading it
/// let url = saved.$photo                  // the stored file, for AsyncImage or QuickLook
/// let bytes = saved.photo                 // read from disk on first access, then cached
/// ```
///
/// A fetched record doesn't load its files. Reading the property loads the file once and keeps it with
/// that copy of the record, so prefer `$photo` where a URL will do, such as for images in a list.
///
/// With CloudKit, a record's files arrive inside it. With a transport that moves files on their own,
/// such as `FileSyncTransport`, records arrive first and their files follow in the background, so a
/// received record's asset reads `nil` until its file lands. Views refresh when it does.
/// `$recipe.downloadProgress` on a `@Recordable` shows how far a record's files have got, and
/// `RecordContext.assetURL(_:of:)` waits for one.
///
/// Outside a container, such as with `JSONEncoder`, the property encodes and decodes as plain `Data?`.
@propertyWrapper
public struct Asset: Hashable, Sendable, Codable {
    enum Source: Sendable {
        case data(Data)
        /// A file to copy in when the record is saved.
        case file(URL)
        /// The asset's file in a container's assets folder.
        case stored(URL)
    }

    final class Storage: @unchecked Sendable {
        let name: String
        let source: Source
        private let lock = NSLock()
        private var cached: Data?

        init(name: String, source: Source) {
            self.name = name
            self.source = source
        }

        func data() -> Data? {
            switch source {
            case .data(let data):
                return data
            case .file(let url), .stored(let url):
                lock.lock()
                defer { lock.unlock() }
                if cached == nil {
                    cached = try? Data(contentsOf: url)
                }
                return cached
            }
        }
    }

    var storage: Storage?

    /// The extension given to new files, such as `"jpg"`.
    public let fileExtension: String

    public init(wrappedValue: Data? = nil, fileExtension: String = "") {
        self.fileExtension = fileExtension
        storage = wrappedValue.map { Storage(name: Self.makeName(fileExtension: fileExtension), source: .data($0)) }
    }

    /// An asset copied from the file at `url` when its record is saved, without reading it into memory.
    init(contentsOf url: URL) {
        fileExtension = url.pathExtension
        storage = Storage(name: Self.makeName(fileExtension: url.pathExtension), source: .file(url))
    }

    init(storedName name: String, url: URL) {
        fileExtension = (name as NSString).pathExtension
        storage = Storage(name: name, source: .stored(url))
    }

    /// The contents, read from disk the first time they're needed.
    public var wrappedValue: Data? {
        get { storage?.data() }
        set { storage = newValue.map { Storage(name: Self.makeName(fileExtension: fileExtension), source: .data($0)) } }
    }

    /// The stored file: `recipe.$photo`. It's `nil` until the record has been saved and fetched back, for
    /// an empty asset, and while a synced record's file is still downloading.
    ///
    /// Assigning a file URL copies that file in when the record is saved, without reading it into memory,
    /// and assigning `nil` clears the asset.
    public var projectedValue: URL? {
        get { url }
        set { self = newValue.map { Asset(contentsOf: $0) } ?? Asset(fileExtension: fileExtension) }
    }

    /// The stored file, or `nil` when it isn't on disk.
    var url: URL? {
        guard case .stored(let url)? = storage?.source, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The file's unique name in the assets folder, or `nil` for an empty asset.
    var name: String? { storage?.name }

    /// The name of a stored file that isn't on disk yet, because it's still on its way from the server.
    var missingName: String? {
        guard case .stored(let url)? = storage?.source, !FileManager.default.fileExists(atPath: url.path) else { return nil }
        return storage?.name
    }

    static func makeName(fileExtension: String) -> String {
        fileExtension.isEmpty ? UUID().uuidString : UUID().uuidString + "." + fileExtension
    }

    // Identity is the file name, because the contents behind a name never change. Comparing names keeps
    // `==` on a record from reading files.
    public static func == (lhs: Asset, rhs: Asset) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    public init(from decoder: Decoder) throws {
        self.init(wrappedValue: try decoder.singleValueContainer().decode(Data?.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Lets a record decode without its asset key, as a plain optional property would.
    public func decode(_ type: Asset.Type, forKey key: Key) throws -> Asset {
        try decodeIfPresent(type, forKey: key) ?? Asset()
    }
}

extension KeyedEncodingContainer {
    /// Leaves an empty asset's key out, as a plain optional property would.
    public mutating func encode(_ value: Asset, forKey key: Key) throws {
        try encodeIfPresent(value.storage == nil ? nil : value, forKey: key)
    }
}
