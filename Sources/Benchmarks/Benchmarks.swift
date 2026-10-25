import Foundation
import SwiftRecords

/// Times the heaviest operations on a large store.
///
/// ```
/// swift run -c release Benchmarks [--recipes 10000] [--save baseline.json] [--compare baseline.json]
/// ```
///
/// Each recipe has five steps, so the default store holds 60,000 records. `--save` writes the timings as
/// JSON, and `--compare` prints each timing's change from a saved run.
@main
struct Benchmarks {
    struct Timing: Codable {
        var name: String
        var records: Int
        var seconds: Double
    }

    struct Options {
        var recipes = 10_000
        var save: String?
        var compare: String?

        init(_ arguments: [String]) throws {
            var arguments = arguments.makeIterator()
            while let argument = arguments.next() {
                switch argument {
                case "--recipes": recipes = try Int(arguments.next() ?? "").orThrow("--recipes takes a number")
                case "--save": save = try arguments.next().orThrow("--save takes a file")
                case "--compare": compare = try arguments.next().orThrow("--compare takes a file")
                default: throw BenchmarkError("Unknown argument \(argument)")
                }
            }
        }
    }

    @MainActor
    static func main() async throws {
        let options = try Options(Array(CommandLine.arguments.dropFirst()))
        let baseline = try options.compare.map {
            try JSONDecoder().decode([Timing].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swift-records-benchmarks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }

        var run = Run(baseline: baseline)
        try await run.all(recipes: options.recipes, in: folder)

        if let path = options.save {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(run.timings).write(to: URL(fileURLWithPath: path))
            say("\nSaved to \(path)")
        }
    }
}

@MainActor
struct Run {
    let baseline: [String: Benchmarks.Timing]?
    private(set) var timings: [Benchmarks.Timing] = []

    init(baseline: [Benchmarks.Timing]?) {
        self.baseline = baseline.map { Dictionary($0.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// Times `body` once, and prints the result next to the baseline's.
    mutating func measure(_ name: String, records: Int, _ body: () async throws -> Void) async throws {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure(body)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        timings.append(.init(name: name, records: records, seconds: seconds))

        var line = name.padding(toLength: 44, withPad: " ", startingAt: 0)
        line += String(format: "%9.1f ms %9.1f µs/record", seconds * 1000, seconds * 1e6 / Double(max(records, 1)))
        if let before = baseline?[name], before.seconds > 0 {
            line += String(format: "  %+6.0f%%", (seconds / before.seconds - 1) * 100)
        }
        say(line)
    }

    mutating func all(recipes count: Int, in folder: URL) async throws {
        let server = BenchmarkServer(name: "first")
        var phone: RecordContainer? = try RecordContainer(
            for: [Recipe.self], directory: folder.appendingPathComponent("phone"), syncProvider: server
        )
        let context = phone!.mainContext
        context.autosaveEnabled = false
        say("Store of \(count) recipes with 5 steps each (\(count * 6) records)\n")

        // MARK: Writing

        let chunk = 500
        try await measure("Import recipes with steps, 500 per save", records: count * 6) {
            try await phone!.performBackgroundTask { background in
                for start in stride(from: 0, to: count, by: chunk) {
                    let recipes = (start..<min(start + chunk, count)).map(Recipe.sample)
                    try background.transaction { try background.insert(recipes) }
                }
            }
        }
        try expect(try context.fetchCount(RecordDescriptor<Step>()) == count * 6 - count, "steps imported")

        let extra = (count..<count + 1_000).map(Recipe.sample)
        try await measure("Insert and save 1,000 on the main context", records: 6_000) {
            for recipe in extra { context.insert(recipe) }
            try Self.commit(context)
        }

        // MARK: Reading

        let total = count + 1_000
        var all: [Recipe] = []
        try await measure("Fetch every recipe with nested steps", records: total * 6) {
            all = try context.fetch(Recipe.self)
        }
        try expect(all.count == total && all.allSatisfy { $0.steps.count == 5 }, "every recipe has its steps")

        let sample = stride(from: 0, to: all.count, by: max(all.count / 1_000, 1)).prefix(1_000).map { all[$0].id }
        try await measure("Fetch 1,000 recipes by ID", records: sample.count * 6) {
            for id in sample { _ = try context.record(Recipe.self, for: id) }
        }

        var found = 0
        try await measure("Fetch by an indexed property", records: total / 8 * 6) {
            found = try context.fetch(RecordDescriptor<Recipe>(predicate: #Predicate { $0.servings == 3 })).count
        }
        try expect(found == (0..<total).filter { $0 % 8 == 2 }.count, "indexed fetch matches")

        try await measure("Fetch by an unindexed property", records: 6) {
            found = try context.fetch(RecordDescriptor<Recipe>(predicate: #Predicate { $0.title == "Recipe 4321" })).count
        }

        try await measure("Count by a range on an unindexed property", records: total) {
            found = try context.fetchCount(RecordDescriptor<Recipe>(predicate: #Predicate { $0.rating >= 2.5 }))
        }

        try await measure("Read 100 pages of 50 from the middle", records: 100 * 50 * 6) {
            for page in 0..<100 {
                _ = try context.fetch(RecordDescriptor<Recipe>(fetchLimit: 50, fetchOffset: total / 2 + page * 50))
            }
        }

        try await measure("Read 100 pages of 50 sorted by a number", records: 100 * 50 * 6) {
            for page in 0..<100 {
                _ = try context.fetch(RecordDescriptor<Recipe>(
                    sortBy: [SortDescriptor(\.rating, order: .reverse)], fetchLimit: 50, fetchOffset: page * 50
                ))
            }
        }

        try await measure("Fetch every recipe sorted by title", records: total * 6) {
            all = try context.fetch(RecordDescriptor<Recipe>(sortBy: [SortDescriptor(\.title)]))
        }

        // MARK: Changing

        let edited = Array(all.prefix(1_000))
        try await measure("Edit and save 1,000 recipes", records: 1_000) {
            for var recipe in edited {
                recipe.title += " (edited)"
                context.insert(recipe)
            }
            try Self.commit(context)
        }

        try await measure("Reorder the steps of 1,000 recipes", records: 6_000) {
            for var recipe in edited {
                recipe.title += " (reordered)"
                recipe.steps.reverse()
                context.insert(recipe)
            }
            try Self.commit(context)
        }

        let doomed = all.suffix(1_000)
        try await measure("Delete 1,000 recipes and cascade to steps", records: 6_000) {
            for recipe in doomed { context.delete(recipe) }
            try Self.commit(context)
        }
        let remaining = total - doomed.count
        try expect(try context.fetchCount(RecordDescriptor<Step>()) == remaining * 5, "steps cascaded")

        // MARK: Syncing

        server.isOnline = true
        try await measure("Upload the whole store", records: remaining * 6) {
            try await context.refresh()
        }
        try expect(server.count == remaining * 6, "server has \(server.count) of \(remaining * 6) records")

        let tablet = try RecordContainer(
            for: [Recipe.self], directory: folder.appendingPathComponent("tablet"), syncProvider: server
        )
        let tabletContext = tablet.mainContext
        tabletContext.autosaveEnabled = false
        _ = try tabletContext.fetchCount(RecordDescriptor<Recipe>())
        try await measure("Download the whole store to a new device", records: remaining * 6) {
            try await tabletContext.refresh()
        }
        try expect(try tabletContext.fetchCount(RecordDescriptor<Recipe>()) == remaining, "new device has every recipe")

        let changed = Array(try context.fetch(RecordDescriptor<Recipe>(fetchLimit: 100, fetchOffset: remaining / 3)))
        for var recipe in changed {
            recipe.servings += 1
            context.insert(recipe)
        }
        try Self.commit(context)
        try await measure("Upload 100 edits from a large store", records: 100) {
            try await context.refresh()
        }
        try await measure("Download 100 edits into a large store", records: 100) {
            try await tabletContext.refresh()
        }

        // A server the store hasn't synced with gets every record, as after moving to a new backend.
        phone = nil
        let newServer = BenchmarkServer(name: "second")
        let moved = try RecordContainer(
            for: [Recipe.self], directory: folder.appendingPathComponent("phone"), syncProvider: newServer
        )
        let movedContext = moved.mainContext
        movedContext.autosaveEnabled = false
        _ = try movedContext.fetchCount(RecordDescriptor<Recipe>())
        newServer.isOnline = true
        try await measure("Resync the whole store with a new server", records: remaining * 6) {
            try await movedContext.refresh()
        }
        try expect(newServer.count == remaining * 6, "new server has \(newServer.count) of \(remaining * 6) records")
    }

    /// Commits without sending, so write timings leave sync out.
    private static func commit(_ context: RecordContext) throws {
        try context.save()
    }

    private func expect(_ condition: @autoclosure () throws -> Bool, _ what: String) throws {
        guard try condition() else { throw BenchmarkError("Check failed: \(what)") }
    }
}

struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let self else { throw BenchmarkError(message) }
        return self
    }
}

/// Prints right away, so the timings so far show even when a check fails.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
