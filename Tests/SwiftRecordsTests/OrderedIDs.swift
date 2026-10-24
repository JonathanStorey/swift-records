import Foundation

extension UUID {
    private static let counter = Counter()

    /// An ID that sorts after every one made before it, the way a time-ordered UUID does, so records in
    /// tests list in the order they were created.
    static func ordered() -> UUID {
        var bytes = UUID().uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            withUnsafeBytes(of: counter.next().bigEndian) { raw.copyBytes(from: $0) }
        }
        return UUID(uuid: bytes)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
