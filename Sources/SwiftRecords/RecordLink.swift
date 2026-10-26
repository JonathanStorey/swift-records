import Foundation

/// One pair in a many-to-many relationship, such as "this recipe has this tag". There is one type for every
/// many-to-many relationship, and the container registers it itself, so an app never declares or sees it.
///
/// Its ID is hashed from the relationship and both ends, so two devices that link the same pair while
/// offline make the same record, and nothing needs merging. Each end is a pointer with `.deleteSelf`, so
/// deleting either record removes the link, here and on a server. It is stored as `RecordLink`, since a
/// CloudKit record type must start with a letter.
struct _RecordLink: Record {
    var id: UUID
    /// The owning property, such as `"Recipe.tags"`.
    var relation: String
    /// The ID of the record whose array holds the link.
    var from: UUID?
    /// The ID of the record it links to.
    var to: UUID?
    /// When the pair was linked, which orders a relationship without `sort:`.
    var created: Date

    init(relation: String, from: UUID, to: UUID, created: Date = Date()) {
        id = Self.id(relation: relation, from: from, to: to)
        self.relation = relation
        self.from = from
        self.to = to
        self.created = created
    }

    static var schema: RecordSchema<_RecordLink> {
        RecordSchema(table: "RecordLink", fields: [
            .field("id", \.id),
            .field("relation", \.relation),
            .anyReference("from", \.from),
            .anyReference("to", \.to),
            .field("created", \.created),
        ])
    }

    /// The version 5 UUID of a pair, the same on every device.
    static func id(relation: String, from: UUID, to: UUID) -> UUID {
        UUID(named: "\(relation)/\(from.uuidString)/\(to.uuidString)", in: namespace)
    }

    /// The namespace link IDs are hashed in.
    private static let namespace = UUID(uuidString: "5C1C7A3E-2D0B-4E4B-9B52-6F3B9A1D2E70")!
}

extension UUID {
    private static let orderedState = OrderedState()

    /// A new ID that sorts after every one this process made before it: a version 7 UUID, which starts with
    /// the time in milliseconds. Records with these IDs list in the order they were created, which is the
    /// order a relationship without `sort:` returns, and IDs made on different devices stay unique.
    public static func ordered() -> UUID {
        let (milliseconds, sequence) = orderedState.next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        bytes[6] = 0x70 | UInt8(truncatingIfNeeded: sequence >> 8)
        bytes[7] = UInt8(truncatingIfNeeded: sequence)
        var random = SystemRandomNumberGenerator()
        let tail = random.next() as UInt64
        bytes[8] = 0x80 | UInt8(truncatingIfNeeded: tail >> 56) & 0x3F
        for index in 9..<16 {
            bytes[index] = UInt8(truncatingIfNeeded: tail >> (8 * (15 - index)))
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The last time and counter `ordered()` used, so IDs made in the same millisecond still go up.
    private final class OrderedState: @unchecked Sendable {
        private let lock = NSLock()
        private var milliseconds: UInt64 = 0
        private var sequence: UInt16 = 0

        func next() -> (milliseconds: UInt64, sequence: UInt16) {
            lock.lock()
            defer { lock.unlock() }
            let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
            if now > milliseconds {
                milliseconds = now
                // A random start leaves room to count up within the millisecond.
                sequence = UInt16.random(in: 0..<0x800)
            } else if sequence < 0xFFF {
                sequence += 1
            } else {
                milliseconds += 1
                sequence = 0
            }
            return (milliseconds, sequence)
        }
    }

    /// The version 5 UUID of `name` in `namespace`, as RFC 9562 defines it.
    init(named name: String, in namespace: UUID) {
        var data = withUnsafeBytes(of: namespace.uuid) { [UInt8]($0) }
        data += Array(name.utf8)
        var hash = Array(SHA1.hash(data).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        self.init(uuid: (
            hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
        ))
    }
}

/// SHA-1, which version 5 UUIDs are defined with. It names link records, and secures nothing.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var bytes = message
        let length = UInt64(message.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: length >> UInt64(shift)))
        }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = x << 1 | x >> 31
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
                }
                let temp = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, b << 30 | b >> 2, a, temp)
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
        }
        return h.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
    }
}
