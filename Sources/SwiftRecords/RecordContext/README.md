# RecordContext

`RecordContext` is where an app reads and edits records, as `ModelContext` is in SwiftData. The context holds edits that are not saved yet, and its `container` holds everything saved. It is built one public member per pull request, following the RecordContext proposal.

## Getting a context

Views use the container's main context.

```swift
let container = try RecordContainer(for: Note.self, Tag.self)
let context = container.mainContext
```

`mainContext` is `@MainActor`. It is made the first time it is read and kept by the container, so every view gets the same context and sees the same unsaved edits.

`RecordContext.init(_ container: RecordContainer)` is internal for now. It is the one place a context is made, and it would become public for background work, as `ModelContext(container)` is in SwiftData.

## Isolation

Like `ModelContext`, a context is not `Sendable` and stays on the actor that created it. The container is the thread-safe part, so a context only needs to hold its own edits.

## Lifetime

The container keeps its main context, and the context keeps its container. Once the main context is used, the two live as long as the app, which is how long a container normally lives anyway.

## Members

| Declaration | What it does |
| --- | --- |
| `@Observable public final class RecordContext` | The context. Observable, so a view reading through it sees records inserted and deleted. |
| `public let container: RecordContainer` | The container it reads from and saves into. |
| `init(_ container: RecordContainer)` | A new context with no edits. Internal. |
| `@MainActor public var mainContext: RecordContext` on `RecordContainer` | The context views use, made once and kept. |
| `@MainActor var storedMainContext: RecordContext?` on `RecordContainer` | Where the container keeps it. Internal. |
| `@Observable final class Draft<Record: Codable>` | A record being edited or deleted and not saved, one per record for the context's life. Internal, in `Drafts.swift`. |
| `enum State { case inserted(Record), deleted }` on `Draft` | The edit, or deleted. A deleted record has no edit. |
| `var base: Record?`, `fileprivate(set) var state: State` on `Draft` | The saved value the edit started from, and the state, which only `Drafts.swift` sets. |
| `var ours: Record?`, `var isDeleted: Bool` on `Draft` | The edit, `nil` when deleted. |
| `func update(_ record: Record)` on `Draft` | Replaces the edit, which also undoes a delete. |
| `func rebase(onto theirs: Record)` on `Draft` | Brings a new saved value in wherever the user did not change it, through `RecordMergeStrategy(favoring: .ours)`, and makes it `base`. A deleted record only moves its `base`. |
| `var hasChanges: Bool` on `Draft` | Whether a save has anything to write: a deleted saved record, or `ours` differing from `base` as JSON. |
| `protocol DraftProtocol: AnyObject` | `isDeleted`, `hasChanges` and `removeReferences(to:)` for a draft of any type. |
| `struct Drafts: Collection` | The open drafts by row, with elements `(key: RecordContainer.RowID, value: any DraftProtocol)`. Every change goes through it. |
| `func draft<Record: Codable>(_ type: Record.Type, at id: RecordContainer.RowID) -> Draft<Record>?` on `Drafts` | The row's draft, deleted or not. |
| `mutating func insert<Record: Codable>(_ record: Record, at id: RecordContainer.RowID, base: () -> Record?)` on `Drafts` | Updates the open draft, or opens one, reading `base` only then. |
| `mutating func open<Record: Codable>(_ saved: Record, at id: RecordContainer.RowID) -> Draft<Record>` on `Drafts` | Opens a draft on a saved value. |
| `mutating func remove<Record: Codable>(_ type: Record.Type, at id: RecordContainer.RowID)` on `Drafts` | Deletes the row and removes it from every other draft's relationship lists in its zone. |
| `var drafts: Drafts` on `RecordContext` | The open drafts. Internal. |
| `public var zone: Zone = "Records"` on `RecordContext` | The zone `insert(_:)` puts a new record in. |
| `public func insert<Record: Codable & Identifiable>(_ record: Record) where Record.ID: Encodable` | Opens a draft for `record`, or replaces the edit of the one already open, undoing a delete. |
| `@discardableResult public func delete<Record: Codable & Identifiable>(_ type: Record.Type, id: Record.ID) -> Record? where Record.ID: Encodable` | Deletes the record in `zone` until save, returning it as it was, or `nil` when there was nothing to delete. |
| `@discardableResult public func delete<Record: Codable & Identifiable>(_ record: Record) -> Record? where Record.ID: Encodable` | The same by the record's id. |

## Inserting

`insert(_:)` writes nothing and never throws, like `ModelContext.insert(_:)`. It holds the Swift value in a `Draft`, so the record is not encoded until `save()`, which throws. The first insert of a record that is already saved reads its saved value, with its relationship lists, as the draft's `base`. If that read fails, `base` stays `nil` and the save merges two ways, so the edit is never lost. A second insert keeps the same `Draft` and replaces only `ours`, so a view watching it keeps watching it.

Two mistakes in an app's code assert in a debug build: inserting a type the container did not register, and an id whose record name is longer than CloudKit's 255 characters. In a release build the draft is kept, and `save()` throws the error.

### Inserting into a list

`insert(_:into:at:)` inserts a child and adds it to a parent's `@References` list, in `zone`. The parent is a value, of which only the id is read when it already has an open edit or a saved value, or an id. An id with no parent, as when another device deleted it, inserts nothing and returns `nil`, since that is a state of the data, not a mistake in the code.

```swift
context.insert(tag, into: note, at: \.tags)
context.insert(tag, into: note.id, at: \Note.tags)
```

A `@References` list cannot be assigned, so the key path is a plain `KeyPath`, and the draft edits the list through its edit's JSON, by the coding key the key path leads to. A child already in the list is not added again. For a relationship list, the child's own list on the other side lists the parent at once, so `record(_:id:)` reads both sides before anything is saved, and the two sides save the same `Relationship`. The other side is found from the parent's list, or else from the child's, since a list decoded with no relationships does not know its inverse.

A key path to a to-one `@Reference` replaces the reference instead of appending. A field list or a to-one reference takes its action, and whether it is a parent, from the property's wrapper, read with `Mirror`, so a value built in code keeps what it declared even when the list is empty or the reference is `nil`. A saved value decoded with an empty list or a `nil` reference has lost them, because Swift never passes the attribute's arguments to `init(from:)`, and then a replaced reference keeps the old one's.

| Declaration | What it does |
| --- | --- |
| `public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parent: Parent, at keyPath: KeyPath<Parent, [Child.ID]>) where Parent.ID: Encodable, Child.ID: Codable` | Inserts `child` into `parent`'s list, inserting `parent` too when it is new. |
| `public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parentID: Parent.ID, at keyPath: KeyPath<Parent, [Child.ID]>) -> Parent? where Parent.ID: Encodable, Child.ID: Codable` | The same by the parent's id, `@discardableResult`. Returns the parent as it now is, or `nil`, inserting nothing, when there is no such parent. |
| `public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parent: Parent, at keyPath: KeyPath<Parent, Child.ID?>) where Parent.ID: Encodable, Child.ID: Codable` | Inserts `child` and points `parent`'s to-one `@Reference` at it. |
| `public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parentID: Parent.ID, at keyPath: KeyPath<Parent, Child.ID?>) -> Parent? where Parent.ID: Encodable, Child.ID: Codable` | The same by the parent's id, returning the parent or `nil` the same way. |
| `func set(_ reference: RecordReference, at key: String) throws` on `Draft` | Points the to-one reference under `key` at a new target. |
| `func wrapper(at key: String) -> (any ReferenceAttributes)?` on `Draft` (private) | The property's wrapper, read with `Mirror`, for its declared action and parent flag. |
| `private protocol ReferenceAttributes` | `action` and `isParent`, adopted by `Reference` and `References`. |
| `extension Reference: JSONSchema.Markable` | Lets a key path to a to-one reference find its coding key, as lists already could. |
| `static func propertyName<Root: Decodable, ID: Decodable & Hashable>(of keyPath: KeyPath<Root, ID?>) throws -> String` on `RecordContainer` | The to-one version of `propertyName(of:)`. |
| `func relate<Parent, Child>(_ child: Draft<Child>, to parent: Draft<Parent>, at keyPath: KeyPath<Parent, [Child.ID]>) throws` (private) | Adds each side to the other's list. |
| `func openedDraft<Record>(_ type: Record.Type, id: Record.ID) -> Draft<Record>?` (private) | The open draft, or one opened from the saved value. |
| `func inverse(ofListAt key: String) -> String?` on `Draft` | The other side of the relationship list under `key`, as in `"Tag.notes"`. |
| `func key(ofListWithInverse property: String) -> String?` on `Draft` | The coding key of the relationship list paired with `property`. |
| `func add(_ reference: RecordReference, toListAt key: String, inverse: String?) throws` on `Draft` | Adds a reference to a field list, or to a relationship list paired with `inverse`. |
| `static func propertyName<Root: Decodable, ID: Decodable & Hashable>(of keyPath: KeyPath<Root, [ID]>) throws -> String` on `RecordContainer` | Moved from `References` and made internal, so the context can find a list's coding key. |

### Removing from a list

`remove(_:from:at:)` undoes `insert(_:into:at:)`, with the same four shapes: a list or a to-one reference, and the parent as a value or an id. Each returns the parent as it now is, `@discardableResult`, or `nil`, changing nothing, when the parent is neither open nor saved, or is deleted. Unlike insert, a new parent passed by value is not added, since there is nothing to remove from it.

The child itself is never deleted. From a relationship list, the parent also leaves the child's own list, opening the child's draft when it is saved, so saving either side removes the `Relationship`. From a field list, the child is untouched. A to-one reference becomes `nil` only when it points at the child. A child that is not there changes nothing, and a draft that does not change is not rewritten, so its views are not woken.

| Declaration | What it does |
| --- | --- |
| `public func remove<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parent: Parent, at keyPath: KeyPath<Parent, [Child.ID]>) -> Parent?` | Removes `child` from `parent`'s list. |
| `public func remove<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parentID: Parent.ID, at keyPath: KeyPath<Parent, [Child.ID]>) -> Parent?` | The same by the parent's id. |
| `public func remove<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parent: Parent, at keyPath: KeyPath<Parent, Child.ID?>) -> Parent?` | Clears `parent`'s to-one reference when it points at `child`. |
| `public func remove<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, from parentID: Parent.ID, at keyPath: KeyPath<Parent, Child.ID?>) -> Parent?` | The same by the parent's id. |
| `func unrelate<Parent, Child>(_ child: Child, from parent: Draft<Parent>, at property: String) throws` (private) | Removes each side from the other's list. |
| `func removeReference(named recordName: String, at key: String)` on `Draft` | Removes a record from the list or reference under `key`. `removeReferences(to:)`, which delete uses, shares its edit. |

All four take `where Parent.ID: Encodable, Child.ID: Codable` and are `@discardableResult`.

## Deleting

`delete(_:)` and `delete(_:id:)` write nothing and never throw, like `ModelContext.delete(_:)`. Each returns the record as it was, its open edit or else its saved value, as `Dictionary.removeValue(forKey:)` returns what it removed. A record already deleted, or neither open nor saved, returns `nil` and changes nothing, so no draft is opened for it. A delete goes through `Drafts.remove`, the only code that can mark a draft deleted, so a delete always does two things together. It sets the record's draft to `.deleted`, opening one with the saved value as `base` if none is open. It also removes the record from the relationship lists of every other draft in its zone, so a Tag being edited cannot recreate the `Relationship` the delete removes.

The draft stays in `drafts` after a delete, even for a record never saved, because a view may hold it. Inserting the record again flips the same draft back to `.inserted`, so every view holding it is told. A deleted draft with no `base` has nothing to save. `record(_:id:)` returns `nil` for a deleted record, and inserting into a deleted parent by its id returns `nil`, while inserting into it by value restores it.

Field lists and to-one references to a deleted record are left alone, as CloudKit leaves them to dangle or to cascade through `.deleteSelf` on the server.

## Fetching

`fetch(_:)` takes a `RecordDescriptor`, as `ModelContext.fetch(_:)` takes a `FetchDescriptor`, and returns the records in `zone`. With `includePendingChanges`, the default, open edits replace their saved values, deleted records are left out, and new records are included, all before the offset and limit apply. Without it, only saved values return.

The database never loads more than the page needs. Every open draft of the type is excluded from the SQL, which then stops at `fetchOffset + fetchLimit` rows with no offset. That margin is exact rather than a guess: whatever the edits are, the page can only hold those saved rows and the edits that match. The matching edits are sorted in with them in Swift, and only then are the offset and limit taken. When no edit matches, the descriptor goes to SQL unchanged, offset included.

| Member | What it is |
|---|---|
| `public func fetch<Record: Codable>(_ descriptor: RecordDescriptor<Record>) throws -> [Record]` | The records `descriptor` describes in `zone`, with open edits applied. Throws what the container's fetch or the predicate throws. |
| `public func fetchCount<Record: Codable>(_ descriptor: RecordDescriptor<Record>) throws -> Int` | How many records `fetch(_:)` would return: the saved count, excluding open drafts, plus the matching edits, then the offset and limit. SQLite counts the saved ones without decoding when the predicate translates exactly. |
| `private func pendingChanges<Record: Codable>(_ descriptor: RecordDescriptor<Record>) throws -> (excluded: [String], pending: [Record])` | The open row names to leave out of SQL, and the edits the predicate matches. |

## Saving

`save()` writes every changed draft in one container transaction. It never lets one record stop the others.

1. Each changed draft is written in turn. An edit is first rebased onto the record's current saved value, so a change saved since the edit began, such as a relationship another device added, is merged in rather than overwritten. A delete removes the record and its relationships. A deleted draft that was never saved has nothing to write.
2. A record that cannot be written keeps its draft open, with its `RecordError` in `error`, and the loop goes on. The container encodes a record fully before it writes anything, so a failure leaves nothing half written.
3. A database error stops the loop and rolls the transaction back, so nothing is written, and `save()` throws `.database`.
4. Once the transaction commits, each written draft's `base` becomes what was written, so it has no changes. Then `save()` throws `.unsaved` if any record failed.

Drafts stay in the context after a save, because views may hold them. An edit clears a draft's error, since the edit may fix it.

| Declaration | What it does |
| --- | --- |
| `public enum SaveError: Error, Equatable` | `.database(DatabaseError)`, when nothing was written, or `.unsaved([String: RecordError])`, the records not written by record name, when everything else was. |
| `public func save() throws(SaveError)` | Writes every change, as above. |
| `public func error<Record: Codable & Identifiable>(_ type: Record.Type, id: Record.ID) -> RecordError? where Record.ID: Encodable` | Why the last save could not write the record, or `nil`. |
| `var error: RecordError?` on `Draft` | The record's last save error, observable, cleared by an edit or a save that writes it. |
| `func write(to container: RecordContainer, at id: RecordContainer.RowID) throws(RecordError)` on `DraftProtocol` | Rebases and writes one draft, leaving `base` alone until the commit. |
| `func didSave()` on `DraftProtocol` | Makes what was written the draft's `base`. |
| `public var hasChanges: Bool` | Whether `save()` would write anything, as `ModelContext.hasChanges`. A draft kept after a save has `base` equal to its edit, so it does not count. |
| `public func rollback()` | Throws away every unsaved change, as `ModelContext.rollback()` does. |
| `func revert()` on `DraftProtocol` | Puts the edit back to `base`, deletes a record never saved, and clears the error. A draft with neither is left alone. |

`rollback()` reverts every draft and keeps them all, so a view holding one sees it reset: an edit shows the saved value again, a deleted record comes back, and a record never saved reads as deleted, with nothing to save.

## Reading

`record(_:id:)` returns the open edit for a record if there is one, and otherwise its saved value, `ours ?? base`, with its relationship lists filled. Every view on a context therefore agrees with what is being edited, as with `ModelContext.model(for:)`. Another context sees only what is saved. It returns `nil` for a record that is missing, deleted, in another zone, or saved in a shape the type cannot decode.

| Declaration | What it does |
| --- | --- |
| `public func record<Record: Codable & Identifiable>(_ type: Record.Type, id: Record.ID) -> Record? where Record.ID: Encodable` | The open edit, or else the saved value, in `zone`. |
| `func rowID<Record>(of type: Record.Type, id: some Encodable) -> RecordContainer.RowID?` (internal) | The row in `zone` for a type and id. |
| `func fetch<T: Decodable>(_ type: T.Type, id: RowID) throws -> T?` on `RecordContainer` (internal) | One row's saved value, with its relationship lists, or `nil`. The context calls it with `try?`. |

## Staying current

A draft would otherwise only catch up with the database at `save()`. Instead, `mainContext` listens to its container's `transactions()` from the moment it is made, on the main actor, and applies each one. Any other context is brought up to date by calling `apply(_:)` with a transaction, which keeps each context on its own actor.

For every open draft of a record the transaction changed, the context reads the saved value again:

- **Saved elsewhere.** An unchanged draft takes the new value. An edited one rebases onto it, so a field only the other side changed comes in and a field the user changed stays.
- **Deleted elsewhere.** An unchanged draft becomes deleted, so views drop it. An edited draft keeps the edit, and its `base` becomes `nil`, so the next save writes it as a new record. Losing someone's typing is worse than bringing back a record someone else deleted.
- **Another process.** A transaction by `RecordContainer.externalAuthor` does not say what changed, so every draft checks.
- **Its own saves.** These come back too, and do nothing, since the saved value already equals `base`.

A relationship saved elsewhere reports both of its records as updated, so an open draft's relationship list follows. A saved record with no relationships has no list in its JSON, while one built in code encodes its empty list, so a draft compares and merges with the saved value's missing lists filled in as empty. Without that, an untouched record would look edited, and its empty list would win a merge over relationships saved elsewhere.

Each transaction also bumps `revision`, which `fetch(_:)`, `fetchCount(_:)` and `record(_:id:)` read. A view that fetched through the context is therefore redrawn when the container changes, even for records with no draft.

| Declaration | What it does |
| --- | --- |
| `func apply(_ transaction: RecordTransaction)` (internal) | Refreshes the drafts the transaction changed, or all of them for another process's, and bumps `revision`. |
| `private(set) var revision: Int` (internal) | Counts the transactions applied. Observable, and read by every read. |
| `@ObservationIgnored var listening: Task<Void, Never>?` (internal) | The task applying `transactions()`, cancelled in `deinit`, which ends the stream. |
| `@MainActor func listen()` (internal) | Starts that task once. `mainContext` calls it. |
| `func refresh(from container: RecordContainer, at id: RecordContainer.RowID)` on `DraftProtocol` | Catches one draft up with its saved row, by the rules above. |
| `private static func aligned(_ saved: Record, with ours: Record) -> Record` on `Draft` | A saved value with empty relationship lists wherever the edit has one and it has none. |
