import Foundation
import Observation
import Versioning

/// A record being edited in a context and not saved yet.
///
/// `base` is the saved value the edit started from, and `ours` is the edit. When the saved
/// value changes underneath, ``rebase(onto:)`` brings the change into `ours` everywhere the
/// user did not change it. A view reads and writes `ours`, so every view on the same draft
/// sees each edit as it is made.
@Observable final class Draft<Record: Codable> {
    /// The saved value the edit started from, or `nil` for a new record.
    var base: Record?
    /// The user's edit.
    var ours: Record

    init(_ ours: Record, base: Record?) {
        self.ours = ours
        self.base = base
    }

    /// Merges `theirs`, the record's new saved value, into the edit, and makes it the new
    /// `base`. A field only `theirs` changed comes in, and a field the user changed stays.
    func rebase(onto theirs: Record) {
        let strategy = RecordMergeStrategy<Record>(favoring: .ours)
        if let base {
            ours = (try? strategy.merge(base: base, ours: ours, theirs: theirs)) ?? ours
        } else {
            // A new record that the saved value overtook: a two-way merge.
            ours = (try? strategy.merge(ours: ours, theirs: theirs)) ?? ours
        }
        base = theirs
    }

    /// Whether the edit differs from `base`, compared as JSON, since a record need not be
    /// `Equatable`.
    var hasChanges: Bool {
        (try? JSONRepresentation(ours)) != base.flatMap { try? JSONRepresentation($0) }
    }
}
