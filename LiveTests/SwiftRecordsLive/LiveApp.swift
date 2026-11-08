import SwiftRecords
import SwiftUI

struct LiveApp: App {
    @State private var run = LiveRun()

    var body: some Scene {
        Window("SwiftRecords Live Tests", id: "main") {
            LiveView(run: run)
                .frame(minWidth: 640, minHeight: 520)
                .task { await run.checkAccount() }
        }
    }
}

struct LiveView: View {
    let run: LiveRun

    var body: some View {
        List {
            Section {
                if run.checks.isEmpty {
                    Label(run.checking ? "Checking…" : "Not checked yet", systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(run.checks, id: \.name) { check in
                    StatusRow(
                        title: check.name, detail: check.detail,
                        symbol: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill",
                        color: check.passed ? .green : .red
                    )
                }
            } header: {
                HStack {
                    Text("Account · \(run.containerName)")
                    Spacer()
                    Button("Check Again") { Task { await run.checkAccount() } }
                        .disabled(run.isBusy)
                }
            }

            Section {
                ForEach(run.rows) { row in
                    ScenarioRow(row: row, busy: run.isBusy) { Task { await run.run(row.scenario) } }
                }
            } header: {
                HStack {
                    Text("Scenarios · \(run.passedCount) passed, \(run.failedCount) failed")
                    Spacer()
                    Button("Run All") { Task { await run.runAll() } }
                        .disabled(run.isBusy)
                }
            }

            Section {
                if run.benchmarking {
                    ProgressView().controlSize(.small)
                }
                if let error = run.benchmarkError {
                    StatusRow(title: "The benchmarks stopped", detail: error, symbol: "xmark.circle.fill", color: .red)
                }
                ForEach(run.benchmarks, id: \.name) { result in
                    HStack {
                        Text(result.name)
                        Spacer()
                        Text(String(format: "%.0f ms", result.milliseconds)).monospacedDigit()
                        Text(String(format: "%.1f ms/record", result.milliseconds / Double(max(result.records, 1))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .trailing)
                    }
                }
            } header: {
                HStack {
                    Text("Benchmarks")
                    Spacer()
                    Stepper("\(run.benchmarkRecords) records", value: Bindable(run).benchmarkRecords, in: 10...1_000, step: 50)
                        .fixedSize()
                    Button("Run") { Task { await run.runBenchmarks() } }
                        .disabled(run.isBusy)
                }
            }
        }
    }
}

struct ScenarioRow: View {
    let row: LiveRun.Row
    let busy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            switch row.state {
            case .waiting:
                StatusRow(title: row.scenario.name, detail: nil, symbol: "circle", color: .secondary)
            case .running:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(row.scenario.name)
                }
            case .passed(let time):
                StatusRow(title: row.scenario.name, detail: time.seconds, symbol: "checkmark.circle.fill", color: .green)
            case .failed(let time, let message):
                StatusRow(
                    title: row.scenario.name, detail: "\(time.seconds) · \(message)", symbol: "xmark.circle.fill", color: .red
                )
            case .skipped(let reason):
                StatusRow(title: row.scenario.name, detail: reason, symbol: "minus.circle", color: .secondary)
            }
            Spacer()
            if !row.scenario.needsOffline {
                Button("Run", action: action).disabled(busy)
            }
        }
    }
}

struct StatusRow: View {
    let title: String
    let detail: String?
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
}
