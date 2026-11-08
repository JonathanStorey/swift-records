import Foundation
import SwiftRecords

// Runs SwiftRecords' sync scenarios and benchmarks on real CloudKit, from Terminal:
//
//   ./run.sh                      account checks, then every scenario
//   ./run.sh benchmarks 200       account checks, then the benchmarks with 200 records
//   ./run.sh all                  checks, scenarios and benchmarks
//   ./run.sh scenarios "edit"     only scenarios whose name contains "edit"
//   ./run.sh list                 the scenario names
//
// It exits 0 when everything passed, 1 when something failed, and 2 when CloudKit can't be reached.

func line(_ text: String = "") {
    print(text)
    fflush(stdout)
}

func seconds(_ duration: Duration) -> String {
    String(format: "%.1f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
}

@MainActor
func runChecks(_ backend: CloudKitBackend) async -> Bool {
    line("Account")
    let checks = await AccountChecks.run(backend)
    for check in checks {
        line("  \(check.passed ? "✔" : "✘") \(check.name): \(check.detail)")
    }
    line()
    return checks.allSatisfy(\.passed)
}

@MainActor
func runScenarios(_ backend: CloudKitBackend, matching filter: String?) async -> Bool {
    let scenarios = SyncScenarios.all.filter { scenario in
        !scenario.needsOffline && (filter.map { scenario.name.localizedCaseInsensitiveContains($0) } ?? true)
    }
    line("Scenarios")
    var failed = 0
    let clock = ContinuousClock()
    for scenario in scenarios {
        let start = clock.now
        do {
            try await scenario.run(on: backend)
            line("  ✔ \(scenario.name) (\(seconds(clock.now - start)))")
        } catch {
            failed += 1
            line("  ✘ \(scenario.name) (\(seconds(clock.now - start)))")
            line("      \(error)")
        }
    }
    let skipped = SyncScenarios.all.filter(\.needsOffline).map(\.name)
    if filter == nil, !skipped.isEmpty {
        line("  Skipped, since CloudKit can't be taken offline here: \(skipped.joined(separator: ", "))")
    }
    line("  \(scenarios.count - failed) of \(scenarios.count) passed")
    line()
    return failed == 0
}

@MainActor
func runBenchmarks(_ backend: CloudKitBackend, records: Int) async -> Bool {
    line("Benchmarks, \(records) records")
    do {
        for result in try await SyncBenchmarks.run(on: backend, records: records) {
            line("  \(result)")
        }
        line()
        return true
    } catch {
        line("  ✘ \(error)")
        line()
        return false
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "scenarios"
let backend = CloudKitBackend()

if command == "list" {
    for scenario in SyncScenarios.all {
        line(scenario.needsOffline ? "\(scenario.name) (in-memory only)" : scenario.name)
    }
    exit(0)
}
guard ["scenarios", "benchmarks", "all", "account"].contains(command) else {
    line("Unknown command \"\(command)\". Use scenarios, benchmarks, all, account or list.")
    exit(2)
}

line("SwiftRecords live tests on \(backend.container.containerIdentifier ?? "no container")")
line()
guard await runChecks(backend) else {
    line("CloudKit can't be reached, so nothing else ran.")
    exit(2)
}
if let swept = try? await backend.sweep(), swept > 0 {
    line("Deleted \(swept) zone(s) left by an earlier run.")
    line()
}

var passed = true
switch command {
case "scenarios":
    passed = await runScenarios(backend, matching: arguments.dropFirst().first)
case "benchmarks":
    passed = await runBenchmarks(backend, records: arguments.dropFirst().first.flatMap(Int.init) ?? 100)
case "all":
    passed = await runScenarios(backend, matching: nil)
    passed = await runBenchmarks(backend, records: 100) && passed
default:
    break
}
exit(passed ? 0 : 1)
