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
| `public final class RecordContext` | The context. |
| `public let container: RecordContainer` | The container it reads from and saves into. |
| `init(_ container: RecordContainer)` | A new context with no edits. Internal. |
| `@MainActor public var mainContext: RecordContext` on `RecordContainer` | The context views use, made once and kept. |
| `@MainActor var storedMainContext: RecordContext?` on `RecordContainer` | Where the container keeps it. Internal. |
| `@Observable final class Draft<Record: Codable>` | A record being edited and not saved. Internal. |
| `var base: Record?`, `var ours: Record` on `Draft` | The saved value the edit started from, and the edit. |
| `func rebase(onto theirs: Record)` on `Draft` | Brings a new saved value in wherever the user did not change it, through `RecordMergeStrategy(favoring: .ours)`, and makes it `base`. |
| `var hasChanges: Bool` on `Draft` | Whether `ours` differs from `base`, compared as JSON. |
| `var drafts: [RecordContainer.RowID: AnyObject]` on `RecordContext` | The open drafts, each a `Draft` of its record's type. Internal. |
| `public var zone: Zone = "Records"` on `RecordContext` | The zone `insert(_:)` puts a new record in. |
| `public func insert<Record: Codable & Identifiable>(_ record: Record) where Record.ID: Encodable` | Opens a draft for `record`, or replaces the edit of the one already open. |

## Inserting

`insert(_:)` writes nothing and never throws, like `ModelContext.insert(_:)`. It holds the Swift value in a `Draft`, so the record is not encoded until `save()`, which throws. The first insert of a record that is already saved reads its saved value, with its relationship lists, as the draft's `base`. If that read fails, `base` stays `nil` and the save merges two ways, so the edit is never lost. A second insert keeps the same `Draft` and replaces only `ours`, so a view watching it keeps watching it.

Two mistakes in an app's code assert in a debug build: inserting a type the container did not register, and an id whose record name is longer than CloudKit's 255 characters. In a release build the draft is kept, and `save()` throws the error.

### Inserting into a list

`insert(_:into:at:)` inserts a child and adds it to a parent's `@References` list, in `zone`. The parent is a value, of which only the id is read when it already has an open edit or a saved value, or an id, which asserts when it has neither.

```swift
context.insert(tag, into: note, at: \.tags)
context.insert(tag, into: note.id, at: \Note.tags)
```

A `@References` list cannot be assigned, so the key path is a plain `KeyPath`, and the draft edits the list through its edit's JSON, by the coding key the key path leads to. A child already in the list is not added again. For a relationship list, the child's own list on the other side lists the parent at once, so `record(_:id:)` reads both sides before anything is saved, and the two sides save the same `Relationship`. The other side is found from the parent's list, or else from the child's, since a list decoded with no relationships does not know its inverse.

| Declaration | What it does |
| --- | --- |
| `public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parent: Parent, at keyPath: KeyPath<Parent, [Child.ID]>) where Parent.ID: Encodable, Child.ID: Codable` | Inserts `child` into `parent`'s list, inserting `parent` too when it is new. |
| `public func insert<Parent: Codable & Identifiable, Child: Codable & Identifiable>(_ child: Child, into parentID: Parent.ID, at keyPath: KeyPath<Parent, [Child.ID]>) where Parent.ID: Encodable, Child.ID: Codable` | The same by the parent's id. |
| `func relate<Parent, Child>(_ child: Draft<Child>, to parent: Draft<Parent>, at keyPath: KeyPath<Parent, [Child.ID]>) throws` (private) | Adds each side to the other's list. |
| `func openedDraft<Record>(_ type: Record.Type, id: Record.ID) -> Draft<Record>?` (private) | The open draft, or one opened from the saved value. |
| `func inverse(ofListAt key: String) -> String?` on `Draft` | The other side of the relationship list under `key`, as in `"Tag.notes"`. |
| `func key(ofListWithInverse property: String) -> String?` on `Draft` | The coding key of the relationship list paired with `property`. |
| `func add(_ reference: RecordReference, toListAt key: String, inverse: String?) throws` on `Draft` | Adds a reference to a field list, or to a relationship list paired with `inverse`. |
| `static func propertyName<Root: Decodable, ID: Decodable & Hashable>(of keyPath: KeyPath<Root, [ID]>) throws -> String` on `RecordContainer` | Moved from `References` and made internal, so the context can find a list's coding key. |

## Reading

`record(_:id:)` returns the open edit for a record if there is one, and otherwise its saved value, `ours ?? base`, with its relationship lists filled. Every view on a context therefore agrees with what is being edited, as with `ModelContext.model(for:)`. Another context sees only what is saved. It returns `nil` for a record that is missing, deleted, in another zone, or saved in a shape the type cannot decode.

| Declaration | What it does |
| --- | --- |
| `public func record<Record: Codable & Identifiable>(_ type: Record.Type, id: Record.ID) -> Record? where Record.ID: Encodable` | The open edit, or else the saved value, in `zone`. |
| `func rowID<Record>(of type: Record.Type, id: some Encodable) -> RecordContainer.RowID?` (private) | The row in `zone` for a type and id. |
| `func fetch<T: Decodable>(_ type: T.Type, id: RowID) throws -> T?` on `RecordContainer` (internal) | One row's saved value, with its relationship lists, or `nil`. The context calls it with `try?`. |
