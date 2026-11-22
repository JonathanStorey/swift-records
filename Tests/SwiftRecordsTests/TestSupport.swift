@testable import SwiftRecords
import Versioning

extension RecordContainer {
    /// An in-memory container with `types` registered. Opening one in memory cannot fail.
    static func inMemory(_ types: [any (Codable & Mergeable).Type]) -> RecordContainer {
        try! RecordContainer(for: types, inMemory: true)
    }

    /// An in-memory container with each of the given types registered.
    static func inMemory(_ type: any (Codable & Mergeable).Type, _ others: any (Codable & Mergeable).Type...) -> RecordContainer {
        inMemory([type] + others)
    }
}
