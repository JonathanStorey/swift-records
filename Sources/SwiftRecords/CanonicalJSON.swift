import Foundation

/// Encodes values to JSON that is identical for equal values. `JSONEncoder` writes a `Set`, and a
/// dictionary whose keys aren't strings or integers, in hash order, which differs between instances. A
/// stored column that changes text without changing value would look like an edit, so this sorts them.
enum CanonicalJSON {
    static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(try capture(value))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// True while comparing records for `hasChanges(in:)`, which skips what the container sets itself, such
    /// as timestamps and inverses, and compares assets by file rather than by contents.
    @TaskLocal static var comparing = false

    /// Captures what a value encodes as a tree, marking the parts whose order carries no meaning.
    static func capture(_ value: some Encodable) throws -> Node {
        if comparing {
            if let asset = value as? Asset {
                // A save may add the file's extension to its name.
                return asset.name.map { .leaf(($0 as NSString).deletingPathExtension) } ?? .null
            }
            if let record = value as? any Record {
                let skipped = type(of: record).containerManagedFields
                let encoder = TreeEncoder()
                try value.encode(to: encoder)
                guard case .keyed(let children) = encoder.root.node else { return encoder.root.node }
                return .keyed(children.filter { !skipped.contains($0.key) })
            }
        }
        // Values `JSONEncoder` writes in its own way, such as `Date` and `Data`, stay whole.
        switch value {
        case is String, is Bool, is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16,
             is UInt32, is UInt64, is Double, is Float, is Date, is Data, is URL, is Decimal, is UUID:
            return .leaf(value)
        default:
            break
        }
        let encoder = TreeEncoder()
        try value.encode(to: encoder)
        let node = encoder.root.node
        if value is any UnorderedCollection, case .unkeyed(let children) = node {
            return .unordered(children, pairs: value is any UnorderedPairs)
        }
        return node
    }

    indirect enum Node: Encodable {
        case leaf(any Encodable)
        case null
        case keyed([(key: String, node: Node)])
        case unkeyed([Node])
        /// A set's elements, or a dictionary's alternating keys and values when `pairs` is true.
        case unordered([Node], pairs: Bool)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .leaf(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            case .keyed(let children):
                var container = encoder.container(keyedBy: AnyCodingKey.self)
                for (key, node) in children {
                    try container.encode(node, forKey: AnyCodingKey(stringValue: key))
                }
            case .unkeyed(let children):
                var container = encoder.unkeyedContainer()
                for node in children {
                    try container.encode(node)
                }
            case .unordered(let children, let pairs):
                var container = encoder.unkeyedContainer()
                let groups = stride(from: 0, to: children.count, by: pairs ? 2 : 1).map {
                    Array(children[$0..<Swift.min($0 + (pairs ? 2 : 1), children.count)])
                }
                // Sort by each element's own JSON, or each pair's key, so the order never depends on hashing.
                let sorted = try groups.map { (try CanonicalJSON.encoder.encode($0[0]), $0) }
                    .sorted { $0.0.lexicographicallyPrecedes($1.0) }
                for (_, group) in sorted {
                    for node in group {
                        try container.encode(node)
                    }
                }
            }
        }
    }
}

/// A collection whose encoded order follows hashing, such as a `Set`.
protocol UnorderedCollection {}
/// A dictionary, which encodes as alternating keys and values when its keys aren't strings or integers.
protocol UnorderedPairs: UnorderedCollection {}

extension Set: UnorderedCollection {}
extension Dictionary: UnorderedPairs {}

// MARK: - Capturing encoder

/// Records what a value encodes, one `Box` per container, so `CanonicalJSON` can reorder it.
private final class TreeEncoder: Encoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    let root = Box()

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(KeyedBox<Key>(box: root.becomeKeyed(), codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        UnkeyedBox(box: root.becomeUnkeyed(), codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleBox(box: root, codingPath: codingPath)
    }
}

private final class Box {
    enum Content {
        case empty
        case node(CanonicalJSON.Node)
        case keyed([(key: String, box: Box)])
        case unkeyed([Box])
    }

    var content = Content.empty

    func becomeKeyed() -> Box {
        if case .keyed = content {} else { content = .keyed([]) }
        return self
    }

    func becomeUnkeyed() -> Box {
        if case .unkeyed = content {} else { content = .unkeyed([]) }
        return self
    }

    func append(key: String) -> Box {
        let child = Box()
        if case .keyed(var children) = content {
            children.append((key, child))
            content = .keyed(children)
        }
        return child
    }

    func append() -> Box {
        let child = Box()
        if case .unkeyed(var children) = content {
            children.append(child)
            content = .unkeyed(children)
        }
        return child
    }

    var node: CanonicalJSON.Node {
        switch content {
        case .empty: .keyed([])
        case .node(let node): node
        case .keyed(let children): .keyed(children.map { ($0.key, $0.box.node) })
        case .unkeyed(let children): .unkeyed(children.map(\.node))
        }
    }
}

/// An encoder for one child box, handed out by `superEncoder` and nested containers.
private struct ChildEncoder: Encoder {
    let box: Box
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(KeyedBox<Key>(box: box.becomeKeyed(), codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        UnkeyedBox(box: box.becomeUnkeyed(), codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleBox(box: box, codingPath: codingPath)
    }
}

private struct KeyedBox<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: Box
    var codingPath: [CodingKey]

    func encodeNil(forKey key: Key) throws {
        box.append(key: key.stringValue).content = .node(.null)
    }

    func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        box.append(key: key.stringValue).content = .node(try CanonicalJSON.capture(value))
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(KeyedBox<NestedKey>(box: box.append(key: key.stringValue).becomeKeyed(), codingPath: codingPath + [key]))
    }

    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        UnkeyedBox(box: box.append(key: key.stringValue).becomeUnkeyed(), codingPath: codingPath + [key])
    }

    func superEncoder() -> Encoder {
        ChildEncoder(box: box.append(key: "super"), codingPath: codingPath)
    }

    func superEncoder(forKey key: Key) -> Encoder {
        ChildEncoder(box: box.append(key: key.stringValue), codingPath: codingPath + [key])
    }
}

private struct UnkeyedBox: UnkeyedEncodingContainer {
    let box: Box
    var codingPath: [CodingKey]
    var count: Int {
        if case .unkeyed(let children) = box.content { return children.count }
        return 0
    }

    func encodeNil() throws {
        box.append().content = .node(.null)
    }

    func encode<T: Encodable>(_ value: T) throws {
        box.append().content = .node(try CanonicalJSON.capture(value))
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(KeyedBox<NestedKey>(box: box.append().becomeKeyed(), codingPath: codingPath))
    }

    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        UnkeyedBox(box: box.append().becomeUnkeyed(), codingPath: codingPath)
    }

    func superEncoder() -> Encoder {
        ChildEncoder(box: box.append(), codingPath: codingPath)
    }
}

private struct SingleBox: SingleValueEncodingContainer {
    let box: Box
    var codingPath: [CodingKey]

    func encodeNil() throws {
        box.content = .node(.null)
    }

    func encode<T: Encodable>(_ value: T) throws {
        box.content = .node(try CanonicalJSON.capture(value))
    }

    func encode(_ value: Bool) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: String) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: Double) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: Float) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: Int) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: Int8) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: Int16) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: Int32) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: Int64) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: UInt) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: UInt8) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: UInt16) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: UInt32) throws { box.content = .node(.leaf(value)) }
    func encode(_ value: UInt64) throws { box.content = .node(.leaf(value)) }
}
