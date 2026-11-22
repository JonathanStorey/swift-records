import Foundation
import Versioning

/// A file stored as a CloudKit asset, read as `Data`, or as your own type holding `Data`,
/// and located by its URL.
///
/// ```swift
/// struct Drawing: RawRepresentable, Mergeable {
///     var rawValue: Data
///     func merging(with theirs: Drawing, from base: Drawing) throws(MergeConflict) -> Drawing { ... }
/// }
///
/// struct Note: Codable, Mergeable {
///     @Asset var attachment: Data? = nil
///     @Asset var drawing: Drawing? = nil
/// }
///
/// note.attachment = bytes           // writes a temporary file
/// note.$attachment = fileURL        // points at a file you own
/// let pdf = PDFDocument(url: note.$attachment!)
/// ```
///
/// The file's URL is the stored value and the projected value. Reading the
/// wrapped value maps the file into memory, so the bytes are paged in only
/// as they are used, and a missing or unreadable file reads as `nil`.
/// Setting the wrapped value writes the bytes to a new file in the temporary
/// directory and points at it, and a failed write leaves the asset `nil`.
///
/// It encodes the URL, not the bytes, so encoding and decoding never touch
/// the disk. Equality compares URLs, so the same bytes in two files are not
/// equal. A `nil` asset is left out of a keyed container, and a missing key
/// decodes as `nil`.
@propertyWrapper
public struct Asset<Value>: Hashable, Sendable {
    /// The file holding the asset's bytes.
    public var projectedValue: URL?

    public init(wrappedValue: Data? = nil) where Value == Data {
        projectedValue = wrappedValue.flatMap { try? $0.writtenToTemporaryFile() }
    }

    public init(wrappedValue: Value? = nil) where Value: RawRepresentable, Value.RawValue == Data {
        projectedValue = wrappedValue.flatMap { try? $0.rawValue.writtenToTemporaryFile() }
    }

    public var wrappedValue: Value? {
        get { bytes.flatMap(Self.value(from:)) }
        set { projectedValue = newValue.flatMap(Self.bytes(of:)).flatMap { try? $0.writtenToTemporaryFile() } }
    }
}

extension Asset {
    /// The file's bytes, mapped into memory, or `nil` when there is no readable file.
    var bytes: Data? {
        projectedValue.flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
    }

    /// `data` as the value: the bytes themselves, or the `RawRepresentable` holding them.
    ///
    /// Decoding builds an asset without knowing which initializer made it, so the value
    /// type is checked here, at run time.
    static func value(from data: Data) -> Value? {
        if let value = data as? Value { return value }
        guard let type = Value.self as? any RawRepresentable.Type else { return nil }
        return type.value(fromRawValue: data) as? Value
    }

    /// The bytes of `value`: the value itself, or its raw value.
    static func bytes(of value: Value) -> Data? {
        if let data = value as? Data { return data }
        return (value as? any RawRepresentable)?.rawValue as? Data
    }
}

private extension RawRepresentable {
    /// A value from `rawValue`, when it is this type's raw value and a valid one.
    static func value(fromRawValue rawValue: Any) -> Self? {
        (rawValue as? RawValue).flatMap(Self.init(rawValue:))
    }
}

/// An `Asset` of any value, for finding one where its value type is unknown.
protocol AnyAsset {
    var projectedValue: URL? { get }
}

extension Asset: AnyAsset {}

extension Asset: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        projectedValue = container.decodeNil() ? nil : try container.decode(URL.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let projectedValue {
            try container.encode(projectedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension Asset: RawRepresentable {
    /// The file holding the asset's bytes, the same as ``projectedValue``,
    /// so a plain `Asset` property works where a wrapper cannot, as in a
    /// SwiftData model.
    public var rawValue: URL? { projectedValue }

    public init(rawValue: URL?) {
        projectedValue = rawValue
    }
}

extension Asset: Mergeable {
    /// The side that changed the file. Two files with the same bytes are the same asset,
    /// so both sides saving the same bytes does not conflict.
    ///
    /// When both sides changed it, a `Mergeable` value merges by its own rule: the bytes of
    /// all three files are read as values, merged, and written to a new file. Any other two
    /// different files conflict.
    public func merging(with theirs: Asset, from base: Asset) throws(MergeConflict) -> Asset {
        if theirs.holdsSameBytes(as: base) || holdsSameBytes(as: theirs) { return self }
        if holdsSameBytes(as: base) { return theirs }
        guard let ours = bytes.flatMap(Self.value(from:)) as? any Mergeable,
              let theirs = theirs.bytes.flatMap(Self.value(from:)),
              let base = base.bytes.flatMap(Self.value(from:)),
              let merged = try ours.merged(with: theirs, from: base) as? Value,
              let data = Self.bytes(of: merged),
              let file = try? data.writtenToTemporaryFile()
        else { throw MergeConflict() }
        return Asset(rawValue: file)
    }

    /// This asset, when both hold the same bytes.
    public func merging(with theirs: Asset) throws(MergeConflict) -> Asset {
        guard holdsSameBytes(as: theirs) else { throw MergeConflict() }
        return self
    }
}

private extension Mergeable {
    /// This value merged with `theirs` from `base`, which must be values of this type,
    /// generic so an existential `Mergeable` opens here.
    func merged(with theirs: Any, from base: Any) throws(MergeConflict) -> Self {
        guard let theirs = theirs as? Self, let base = base as? Self else { throw MergeConflict() }
        return try merging(with: theirs, from: base)
    }
}

private extension Asset {
    /// Whether both point at the same file, or at files with the same bytes.
    func holdsSameBytes(as other: Asset) -> Bool {
        if projectedValue == other.projectedValue { return true }
        guard let bytes else { return false }
        return bytes == other.bytes
    }
}

// Synthesized `Codable` calls these instead of the generic methods, so a
// `nil` asset behaves like an optional property.
extension KeyedDecodingContainer {
    public func decode<Value>(_ type: Asset<Value>.Type, forKey key: Key) throws -> Asset<Value> {
        try decodeIfPresent(type, forKey: key) ?? Asset(rawValue: nil)
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<Value>(_ value: Asset<Value>, forKey key: Key) throws {
        guard value.projectedValue != nil else { return }
        try encodeIfPresent(Optional(value), forKey: key)
    }
}

private extension Data {
    func writtenToTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try write(to: url, options: .atomic)
        return url
    }
}
