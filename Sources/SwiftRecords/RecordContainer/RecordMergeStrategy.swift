import Foundation
import Versioning

/// How the container merges every record, so a merge never throws a conflict.
///
/// A record need only be `Codable`. When it is also `Mergeable`, its own merge runs first,
/// which keeps a hand-written one, as `Relationship` has. Otherwise, or where that conflicts,
/// ``DefaultMergeStrategy`` keeps `favoring` at each conflicting value and still merges each
/// `Mergeable` property by its own merge.
struct RecordMergeStrategy<Value: Codable>: MergeStrategy {
    /// The merge run when the type has no merge of its own, or its own merge conflicts.
    let fallback: DefaultMergeStrategy<Value>

    init(favoring side: KeepMerge<JSONRepresentation>) {
        fallback = DefaultMergeStrategy(favoring: side == .ours ? .ours : .theirs)
    }

    func merge(base: Value, ours: Value, theirs: Value) throws(MergeConflict) -> Value {
        if let merged = try? (ours as? any Mergeable)?.merged(with: theirs, from: base) as? Value { return merged }
        return try fallback.merge(base: base, ours: ours, theirs: theirs)
    }

    func merge(ours: Value, theirs: Value) throws(MergeConflict) -> Value {
        if let merged = try? (ours as? any Mergeable)?.merged(with: theirs, from: nil) as? Value { return merged }
        return try fallback.merge(ours: ours, theirs: theirs)
    }
}

private extension Mergeable {
    /// This value merged with `theirs`, from `base` when there is one, by its own merge.
    /// Both must be values of this type. Generic, so an existential `Mergeable` opens here.
    func merged(with theirs: Any, from base: Any?) throws(MergeConflict) -> Self {
        guard let theirs = theirs as? Self else { throw MergeConflict() }
        guard let base else { return try merging(with: theirs) }
        guard let base = base as? Self else { throw MergeConflict() }
        return try merging(with: theirs, from: base)
    }
}
