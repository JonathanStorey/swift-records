import Foundation
import SwiftRecords

/// One timed step of a sync benchmark.
public struct SyncBenchmarkResult: Sendable, CustomStringConvertible {
    public let name: String
    public let records: Int
    public let duration: Duration

    public var milliseconds: Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    public var description: String {
        let total = String(format: "%10.1f ms", milliseconds)
        let each = String(format: "%9.1f ms/record", milliseconds / Double(max(records, 1)))
        return "\(name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(total) \(each)"
    }
}

/// Times the sync steps whose cost depends on how records are batched: one save of many records against
/// one save each, then downloading, editing and deleting them all. Each run uses a zone of its own.
public enum SyncBenchmarks {
    @MainActor
    public static func run(on backend: any SyncBackend, records count: Int) async throws -> [SyncBenchmarkResult] {
        let zone = try backend.freshZone()
        do {
            let results = try await steps(backend, zone, count)
            await backend.cleanUp(zone)
            return results
        } catch {
            await backend.cleanUp(zone)
            throw error
        }
    }

    @MainActor
    private static func steps(_ backend: any SyncBackend, _ zone: Zone, _ count: Int) async throws -> [SyncBenchmarkResult] {
        let clock = ContinuousClock()
        var results: [SyncBenchmarkResult] = []
        func time(_ name: String, _ records: Int, _ body: () async throws -> Void) async rethrows {
            let start = clock.now
            try await body()
            results.append(SyncBenchmarkResult(name: name, records: records, duration: clock.now - start))
        }

        let (phone, laptop) = try backend.pair(zone)
        var notes = (0..<count).map { ScenarioNote(text: "Batch \($0)", position: $0) }
        try await time("Upload \(count) notes in one save", count) {
            for note in notes { phone.context.insert(note) }
            try await phone.context.save()
        }
        try check(phone.context.status == .saved, "the batch upload ended \(phone.context.status)")

        let singles = (0..<count).map { ScenarioNote(text: "Single \($0)", position: $0) }
        try await time("Upload \(count) notes, one save each", count) {
            for note in singles {
                phone.context.insert(note)
                try await phone.context.save()
            }
        }
        try check(phone.context.status == .saved, "the one-at-a-time upload ended \(phone.context.status)")

        try await time("Download \(count * 2) notes on another device", count * 2) {
            try await backend.eventually(laptop, "not every note arrived") {
                try laptop.context.fetch(ScenarioNote.self).count == count * 2
            }
        }

        try await time("Edit one property of \(count) notes in one save", count) {
            for index in notes.indices {
                notes[index].pinned = true
                phone.context.insert(notes[index])
            }
            try await phone.context.save()
        }

        try await time("Delete \(count * 2) notes in one save", count * 2) {
            phone.context.delete(record: ScenarioNote.self)
            try await phone.context.save()
        }
        try check(phone.context.status == .saved, "the deletion ended \(phone.context.status)")
        return results
    }
}
