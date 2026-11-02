import Foundation
@_spi(SyncProvider) @testable import SwiftRecords
import Testing

@Record
struct Diary {
    var id = UUID()
    var title = ""
    @Encrypted var entry = ""
}

/// `@Encrypted` properties go to the server flagged, so a CloudKit provider stores them in `encryptedValues`.
@MainActor
@Suite struct EncryptedTests {
    let server = TestServer()

    @Test func uploadsNameTheEncryptedFields() async throws {
        let container = try RecordContainer(for: [Diary.self], inMemory: true, syncProvider: TestProvider(server: server))
        let diary = Diary(title: "Monday", entry: "Private")
        container.mainContext.insert(diary)
        try await container.mainContext.save()

        let saved = try #require(server.record("Diary", diary.id))
        #expect(saved.encryptedKeys == ["entry"])
        #expect(saved.fields?["entry"] == .string("Private"))
    }

    @Test func encryptedFieldsComeBackAsAnyOther() async throws {
        let phone = try RecordContainer(for: [Diary.self], inMemory: true, syncProvider: TestProvider(server: server))
        let diary = Diary(title: "Monday", entry: "Private")
        phone.mainContext.insert(diary)
        try await phone.mainContext.save()

        let tablet = try RecordContainer(for: [Diary.self], inMemory: true, syncProvider: TestProvider(server: server))
        try await tablet.mainContext.refresh()
        #expect(try tablet.mainContext.record(Diary.self, for: diary.id)?.entry == "Private")
    }
}
