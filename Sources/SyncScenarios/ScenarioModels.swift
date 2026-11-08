import Foundation
import SwiftRecords

// The records the scenarios sync. Their names start with `Scenario` so they stay apart from an app's own
// record types in a CloudKit schema.

@Record
struct ScenarioNotebook {
    var id = UUID()
    var title: String
    var color = "blue"
    @Reference(to: \ScenarioNote.notebook, sort: \.position) var notes: [ScenarioNote] = []
    @Reference(to: ScenarioTag.self) var tags: [ScenarioTag] = []
}

@Record
struct ScenarioNote {
    var id = UUID()
    var text: String
    var position = 0
    var pinned = false
    var words: [String] = []
    var due: Date?
    @Timestamped(.modified) var modified: Date?
    @Asset var attachment: Data? = nil
    @Reference(from: ScenarioNotebook.self, action: .deleteSelf) var notebook: ScenarioNotebook.ID?
}

@Record
struct ScenarioTag {
    var id = UUID()
    var name: String
    @Reference(to: \ScenarioNotebook.tags) var notebookIDs: Set<ScenarioNotebook.ID>
}

/// Every record type the scenarios use.
let scenarioTypes: [any Record.Type] = [ScenarioNotebook.self, ScenarioNote.self, ScenarioTag.self]
