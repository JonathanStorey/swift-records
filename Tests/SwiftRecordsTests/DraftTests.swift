import Foundation
import Observation
import Testing
@testable import SwiftRecords
import Versioning

private struct Hits: Codable, Mergeable, RawRepresentable {
    var rawValue: Int
    func merging(with theirs: Hits, from base: Hits) throws(MergeConflict) -> Hits {
        Hits(rawValue: rawValue + theirs.rawValue - base.rawValue)
    }
}

private struct Card: Codable, Equatable {
    var front = "", back = ""
    var tags: Set<String> = []
}

private struct Counted: Codable {
    var title = ""
    var hits = Hits(rawValue: 0)
}

@Suite struct DraftTests {
    @Test func aRebaseBringsInWhatOnlyTheServerChanged() {
        let draft = Draft(Card(front: "Mine"), base: Card())
        draft.rebase(onto: Card(back: "Theirs"))
        #expect(draft.ours == Card(front: "Mine", back: "Theirs"))
    }

    @Test func aRebaseKeepsWhatTheUserChanged() {
        let draft = Draft(Card(front: "Mine"), base: Card())
        draft.rebase(onto: Card(front: "Theirs", back: "Theirs"))
        #expect(draft.ours == Card(front: "Mine", back: "Theirs"))
    }

    @Test func aRebaseKeepsBothSidesAdditionsToASet() {
        let draft = Draft(Card(tags: ["a", "mine"]), base: Card(tags: ["a"]))
        draft.rebase(onto: Card(tags: ["a", "theirs"]))
        #expect(draft.ours?.tags == ["a", "mine", "theirs"])
    }

    @Test func aRebaseMergesAMergeablePropertyByItsOwnMerge() {
        let draft = Draft(Counted(hits: Hits(rawValue: 4)), base: Counted(hits: Hits(rawValue: 3)))
        draft.rebase(onto: Counted(hits: Hits(rawValue: 5)))
        #expect(draft.ours?.hits.rawValue == 6, "Both raised it, so it sums.")
    }

    @Test func aRebaseMovesTheBaseForward() throws {
        let draft = Draft(Card(front: "Mine"), base: Card())
        draft.rebase(onto: Card(back: "Theirs"))
        #expect(draft.base == Card(back: "Theirs"))
        #expect(draft.hasChanges, "The user's front is still unsaved.")
    }

    @Test func hasChangesComparesTheEditWithItsBase() {
        let draft = Draft(Card(), base: Card())
        #expect(!draft.hasChanges)
        draft.update(Card(front: "Mine"))
        #expect(draft.hasChanges)
        #expect(Draft(Card(), base: nil).hasChanges, "A new record is a change.")
    }

    @Test func aViewReadingTheDraftIsToldOfAnEdit() {
        let draft = Draft(Card(), base: Card())
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = draft.ours } onChange: { changed = true }
        draft.update(Card(front: "Mine"))
        #expect(changed)
    }
}
