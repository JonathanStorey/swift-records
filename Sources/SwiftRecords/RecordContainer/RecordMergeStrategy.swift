import Foundation
import Versioning

/// How the container merges every record, so a merge never throws a conflict.
///
/// The type's own merge runs first, which keeps a hand-written one, as `Relationship` has.
/// Where that conflicts, ``DefaultMergeStrategy`` keeps `favoring` at each conflicting value
/// and still merges each `Mergeable` property by its own merge.
struct RecordMergeStrategy<Value: Codable & Mergeable>: MergeStrategy {
    /// The merge run where the type's own merge conflicts.
    let fallback: DefaultMergeStrategy<Value>

    init(favoring side: KeepMerge<JSONRepresentation>) {
        fallback = DefaultMergeStrategy(favoring: side == .ours ? .ours : .theirs)
    }

    func merge(base: Value, ours: Value, theirs: Value) throws(MergeConflict) -> Value {
        do { return try ours.merging(with: theirs, from: base) } catch { return try fallback.merge(base: base, ours: ours, theirs: theirs) }
    }

    func merge(ours: Value, theirs: Value) throws(MergeConflict) -> Value {
        do { return try ours.merging(with: theirs) } catch { return try fallback.merge(ours: ours, theirs: theirs) }
    }
}
