import Foundation
import Observation
import SwiftRecords

/// What the window shows: the account checks, each scenario's state, and the benchmark results.
@MainActor
@Observable
final class LiveRun {
    enum State: Equatable {
        case waiting
        case running
        case passed(Duration)
        case failed(Duration, String)
        case skipped(String)
    }

    struct Row: Identifiable {
        let scenario: SyncScenario
        var state: State
        var id: String { scenario.name }
    }

    let backend = CloudKitBackend()
    private(set) var checks: [AccountChecks.Check] = []
    private(set) var checking = false
    private(set) var rows: [Row]
    private(set) var benchmarks: [SyncBenchmarkResult] = []
    private(set) var benchmarkError: String?
    private(set) var benchmarking = false
    var benchmarkRecords = 100
    private var swept = false

    init() {
        rows = SyncScenarios.all.map { scenario in
            Row(scenario: scenario, state: scenario.needsOffline ? .skipped("in-memory only") : .waiting)
        }
    }

    var containerName: String { backend.container.containerIdentifier ?? "no iCloud container" }
    var isBusy: Bool { checking || benchmarking || rows.contains { $0.state == .running } }
    var accountReady: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
    var passedCount: Int { rows.filter { if case .passed = $0.state { true } else { false } }.count }
    var failedCount: Int { rows.filter { if case .failed = $0.state { true } else { false } }.count }

    func checkAccount() async {
        checking = true
        checks = await AccountChecks.run(backend)
        checking = false
        if accountReady, !swept {
            swept = true
            _ = try? await backend.sweep()
        }
    }

    /// Checks the account first if it hasn't been, then runs every scenario CloudKit can run, in order.
    func runAll() async {
        guard await ready() else { return }
        for index in rows.indices where rows[index].state != .skipped("in-memory only") {
            rows[index].state = .waiting
        }
        for row in rows where !row.scenario.needsOffline {
            await run(row.scenario)
        }
    }

    func run(_ scenario: SyncScenario) async {
        guard await ready(), let index = rows.firstIndex(where: { $0.id == scenario.name }) else { return }
        rows[index].state = .running
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await scenario.run(on: backend)
            rows[index].state = .passed(clock.now - start)
        } catch {
            rows[index].state = .failed(clock.now - start, "\(error)")
        }
    }

    func runBenchmarks() async {
        guard await ready() else { return }
        benchmarking = true
        benchmarks = []
        benchmarkError = nil
        do {
            benchmarks = try await SyncBenchmarks.run(on: backend, records: benchmarkRecords)
        } catch {
            benchmarkError = "\(error)"
        }
        benchmarking = false
    }

    private func ready() async -> Bool {
        if checks.isEmpty { await checkAccount() }
        return accountReady
    }
}
