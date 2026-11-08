import Foundation
import SwiftRecords

/// Where a scenario's devices sync: the in-memory server in the package's tests, or CloudKit in the live
/// app. Each device is its own container, with its own store and sync engine, on the same account.
@MainActor
public protocol SyncBackend {
    /// A name for reports, such as "in-memory" or "CloudKit".
    var name: String { get }

    /// Whether the backend can cut devices off from the server, for scenarios about offline edits.
    var canGoOffline: Bool { get }

    /// How many times a check that waits on the server tries before it fails, and the pause between tries.
    /// The in-memory server is consistent at once. CloudKit can take a moment to show a save to a fetch.
    var attempts: Int { get }
    var pause: Duration { get }

    /// A new device that starts in `zone` and syncs only when a context asks.
    func makeDevice(_ types: [any Record.Type], zone: Zone) throws -> RecordContainer

    /// A zone no earlier run has used.
    func freshZone() throws -> Zone

    /// Cuts every device off from the server, or reconnects them. Only called when `canGoOffline`.
    func setOnline(_ online: Bool)

    /// Removes what a run left on the server.
    func cleanUp(_ zone: Zone) async
}

/// A check in a scenario that didn't hold.
public struct ScenarioFailure: Error, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Fails the scenario with `message` unless `condition` holds.
public func check(
    _ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line
) throws {
    guard condition else { throw ScenarioFailure("\(message()) (\(file):\(line))") }
}

extension SyncBackend {
    /// Refreshes `device` until `condition` holds, as many times as the backend allows.
    public func eventually(
        _ device: RecordContainer, _ message: @autoclosure () -> String,
        file: StaticString = #fileID, line: UInt = #line, _ condition: () throws -> Bool
    ) async throws {
        for attempt in 1...max(attempts, 1) {
            try await device.mainContext.refresh()
            if try condition() { return }
            if attempt < attempts { try await Task.sleep(for: pause) }
        }
        throw ScenarioFailure("\(message()) after \(attempts) refreshes (\(file):\(line))")
    }
}
