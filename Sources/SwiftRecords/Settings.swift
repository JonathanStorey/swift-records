import Foundation

extension Array where Element: Record {
    /// The record `@RecordStorage` shows when a zone holds several, which happens only when devices each
    /// stored one before syncing: the lowest ID, which `UUID.ordered()` makes the oldest. Every device picks
    /// the same one without asking the others.
    var setting: Element? {
        self.min { $0.id.uuidString < $1.id.uuidString }
    }
}

extension RecordContext {
    /// Stores a setting: saves `value` if it changed and deletes every other record in the zone, so
    /// duplicates from devices that stored one before syncing collapse back to one.
    func storeSetting<R: Record>(_ value: R, replacing current: [R], in zone: Zone) {
        if current.first(where: { $0.id == value.id }).map({ !StructuralEquality.equal($0, value) }) ?? true {
            insert(value, in: zone)
        }
        for record in current where record.id != value.id {
            delete(record, in: zone)
        }
    }
}
