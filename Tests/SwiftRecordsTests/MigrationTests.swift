import Foundation
@testable import SwiftRecords
import Testing

@Suite struct MigrationTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    @Test func filesFromVersion030LoseTheirBookkeepingColumns() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let ana = Person(name: "Ana")
        let url: URL
        do {
            let container = try RecordContainer(directory: directory)
            try container.save(ana)
            url = try #require(container.url)
        }

        // Shape the file as 0.3.0 left it: tracking columns beside the record, with a tag in them.
        let old = try SQLiteDatabase(url: url)
        for column in ["\"_version\" INTEGER NOT NULL DEFAULT 0", "\"_modified\"", "\"_tag\""] {
            try old.execute("ALTER TABLE \"Person\" ADD COLUMN \(column)")
        }
        try old.run("UPDATE \"Person\" SET \"_version\" = 1, \"_tag\" = ?", [.blob(Data([7]))])
        try old.execute("PRAGMA user_version = 0")

        let container = try RecordContainer(directory: directory)
        let columns = try container.defaultStorage.store.db.run("PRAGMA table_info(\"Person\")").compactMap { row -> String? in
            if case .text(let name)? = row["name"] { return name }
            return nil
        }
        #expect(Set(columns) == ["id", "_position", "name"])
        #expect(try container.metadata(Person.self, id: ana.id)?.tag == Data([7]))
        #expect(try container.fetch(Person.self).map(\.name) == ["Ana"])
    }
}
