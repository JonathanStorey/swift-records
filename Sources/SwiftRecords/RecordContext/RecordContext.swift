import Foundation

/// The place an app reads and edits records, as `ModelContext` is in SwiftData.
///
/// A context holds the edits not saved yet, and its ``container`` holds everything saved.
/// Views use the container's ``RecordContainer/mainContext``.
///
/// ```swift
/// let container = try RecordContainer(for: Note.self, Tag.self)
/// let context = container.mainContext
/// ```
///
/// Like `ModelContext`, a context is not `Sendable`. It stays on the actor that created it.
public final class RecordContext {
    /// The container this context reads from and saves into.
    public let container: RecordContainer
    /// The open drafts, each a ``Draft`` of its record's type, by the row they edit.
    var drafts: [RecordContainer.RowID: AnyObject] = [:]
    /// The zone that ``insert(_:)`` puts a new record in. An existing record keeps its own
    /// zone, so changing this never moves one.
    public var zone: Zone = "Records"

    /// A new context on `container`, with no edits.
    init(_ container: RecordContainer) {
        self.container = container
    }
}

extension RecordContext {
    /// Starts editing `record` in ``zone``, or replaces the edit already open for it.
    ///
    /// Nothing is written until `save()`, which is also where a record that cannot be
    /// saved throws. A record already saved keeps its saved value as the draft's base, so a
    /// save merges in whatever changed meanwhile.
    ///
    /// ```swift
    /// context.insert(Note(title: "Groceries"))
    /// ```
    public func insert<Record: Codable & Identifiable>(_ record: Record) where Record.ID: Encodable {
        let type = RecordContainer.recordType(of: Record.self)
        assert((try? container.registeredType(named: type)) != nil, "\(type) is not registered. Pass it to RecordContainer(for:).")
        guard let name = try? RecordContainer.recordName(for: record.id, type: type, checkingLength: false) else {
            assertionFailure("The id of \(type) \(record.id) cannot be encoded as a record name.")
            return
        }
        assert(name.utf8.count <= 255, "The record name \(name) is longer than CloudKit's 255 characters. Use a shorter id.")
        let id = RecordContainer.RowID(name: name, zone: zone)
        if let draft = drafts[id] as? Draft<Record> {
            draft.ours = record
        } else {
            let saved = try? container.fetch(Record.self, in: zone, where: (clause: "id = ?", values: [name], isExact: true)).first
            drafts[id] = Draft(record, base: saved)
        }
    }
}

extension RecordContainer {
    /// The context views use, created on first use and the same one every time after.
    ///
    /// The container keeps it, and it keeps the container, so a container lives as long as
    /// the app once its main context is used, as a container normally does anyway.
    @MainActor public var mainContext: RecordContext {
        if let context = storedMainContext { return context }
        let context = RecordContext(self)
        storedMainContext = context
        return context
    }
}
