import Foundation
import Testing
@testable import SwiftRecords
import Versioning

@Suite struct RecordContainerRowTests {
    private let row = RecordContainer.Row(id: UUID().uuidString, zone: "Notes", type: "Note", base: ["title": "Base"])

    @Test func aRowWithNothingWaitingIsSynced() {
        #expect(row.status == .synced)
        #expect(row.zone.owner == "__defaultOwner__")
    }

    @Test func savedChangesAndDeletesWaitToUpload() {
        var changed = row
        changed.ours = ["title": "Ours"]
        #expect(changed.status == .waitingToUpload)

        var deleted = row
        deleted.isDeleted = true
        #expect(deleted.status == .waitingToUpload)
    }

    @Test func anErrorWithoutTheirsIsARejectedUpload() {
        var rejected = row
        rejected.ours = ["title": "Ours"]
        rejected.error = "Record too large"
        #expect(rejected.status == .rejected("Record too large"))
    }

    @Test func theirsOutranksEverythingElse() {
        var waiting = row
        waiting.ours = ["title": "Ours"]
        waiting.isDeleted = true
        waiting.theirs = ["title": "Theirs"]
        #expect(waiting.status == .conflict(""))

        waiting.error = "title changed on both sides"
        #expect(waiting.status == .conflict("title changed on both sides"))
    }

    @Test func aConfirmedUploadBecomesTheBase() {
        var sent = row
        sent.ours = ["title": "Ours"]
        sent.error = "Record too large"
        sent.confirm(["title": "Ours"])
        #expect(sent.base == ["title": "Ours"])
        #expect(sent.ours == nil)
        #expect(sent.status == .synced)
    }

    @Test func changesSavedDuringAnUploadStayWaitingWithoutAConflict() {
        var new = RecordContainer.Row(id: UUID().uuidString, zone: "Notes", type: "Note", ours: ["title": "Typed later"])
        new.confirm(["title": "Typed first"])
        #expect(new.base == ["title": "Typed first"])
        #expect(new.ours == ["title": "Typed later"])
        #expect(new.status == .waitingToUpload)
    }
}
