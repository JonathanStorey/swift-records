# swift-records

A SQLite-backed store for plain Swift structs. Mark a struct with `@Record`, and nested records are
saved to their own tables automatically.

```swift
import SwiftRecords

@Record
struct ToDo {
    var id = UUID()
    var title: String
    var done = false
    var owner: Person?                                   // to-one relationship
    @Reference(deleteRule: .none) var notes: [Note] = []  // to-many, order kept
    var tags: [String] = []                              // plain Codable, stored as JSON
}

@Record
struct Note {
    var id = UUID()
    var text: String
    @Reference(from: \ToDo.notes) var todos: [ToDo.ID] = []  // inverse, order kept
}
```

Every record's `id` is a `UUID`, so records created on different devices never collide. IDs are
stored as 16-byte blobs, which keeps primary keys and join tables compact.

## Containers and contexts

The shape follows SwiftData. A `RecordContainer` owns a zone's file, its assets and the schema. You
read and write through a context.

```swift
let container = try RecordContainer()                // the default zone
let context = container.mainContext                  // one per container, on the main actor

context.save(todo)                                   // the ToDo, its Person and every Note
let open = try context.fetch(ToDo.self, where: #Predicate { !$0.done })
let parents = try context.fetch(ToDo.self, ids: note.todos)
context.delete(todo)
try context.save()                                   // or let autosave commit once edits pause
```

The main context collects changes and commits them together, either when you call `save()` or
automatically once edits pause for `autosaveDelay`. Every fetch saves first, so results include your
own edits. Records come back in their stored order. To show them in another order, sort a copy.

For work off the main actor, such as an import, use a background context. Its saves commit right away,
`transaction(_:)` groups several into one commit, and the main context refreshes after each commit.

```swift
try await container.performBackgroundTask { context in
    try context.transaction {
        for item in downloaded { try context.save(item) }
    }
}
```

## Zones

A zone is a named database file. The name is the file name without its extension.

```swift
extension Zone {
    static let drafts: Zone = "drafts"
}

let main = try RecordContainer()                     // Application Support/Records/default.sqlite
let drafts = try RecordContainer(zone: .drafts)      // Application Support/Records/drafts.sqlite
let scratch = try RecordContainer(zone: .inMemory)   // nothing on disk
```

Zone files are local to the device and never sync through iCloud. They are included in the device's
own backups (iCloud or computer, whichever the user chose) and in phone-to-phone transfers. On macOS the folder sits inside one named for the
app's bundle identifier. Relationships stay within one zone, and the same record type can be stored
in several zones. To open a file somewhere else, use `RecordContainer(url:)`.

## Queries

Simple predicates on a record's own properties run as SQL: `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`,
`||`, `!`, `nil` checks, `[values].contains(\.property)`, `String.contains` (iOS 18 / macOS 15) and
`localizedStandardContains`. Searching inside a to-many relationship also runs as SQL:

```swift
let greeted = try context.fetch(ToDo.self, where: #Predicate { todo in
    todo.notes.contains { $0.text == "hello world" }
})
```

Anything else is evaluated in memory, so every predicate works.

## Changing a record type

- **New properties** read their declared default from rows saved before they existed, such as
  `var servings = 2`. Optionals read as `nil`. A new non-optional property needs a default.
- **Renamed properties** keep their values with `@Renamed(from: "minutes") var duration = 0`. The
  column (or a relationship's join table) is renamed the first time the container uses the type.
- **Renamed types** keep their data with `@Record(name: "Recipe")`, which fixes the stored name.
- `@Indexed` adds an index to a property that predicates compare, and changes nothing about encoding.
- Generic structs can't be records, since each specialization would need its own fixed name.

## Relationships

- Any property whose type is a `@Record`, an optional `@Record` or an array of them is a relationship.
  It is stored in a join table named `Owner.property` that keeps the order of both sides.
- Delete rules: `.cascade` (the default, like a nested struct) and `.none`, which unlinks and keeps them. Cascade only
  deletes records nothing else still references, and it also applies when a record is removed from
  an array.
- An inverse, `@Reference(from:)`, holds the owners' IDs in order. Loading full records eagerly would
  recurse forever with value types, so fetch them with `context.fetch(_:ids:)`. Reordering the IDs and
  saving persists the new order.

## Assets

Large data such as photos and audio belongs in an `@Asset` property, which stores its `Data?` as a
file beside the database instead of inside it.

```swift
@Record
struct Photo {
    var id = UUID()
    @Asset(fileExtension: "jpg") var image: Data? = nil
}

context.save(Photo(image: jpeg))
let photo = try context.fetch(Photo.self).first
let url = photo?.$image.url      // the stored file, for AsyncImage, QuickLook or AVPlayer
let bytes = photo?.image         // read from disk on first access, then cached
```

- Fetching never reads asset files. The bytes load the first time the property is read, so prefer
  `$image.url` where a URL will do.
- Files live in a folder named after the database file, such as `Records/default.assets/`, so they
  are included in device backups along with the zone.
- Assigning new data or `nil` removes the old file when the record is saved, and deleting a record
  (directly or by cascade) removes its files. Rolled-back transactions leave no files behind.
- To copy a large file in without loading it, assign `photo.$image = Asset(contentsOf: url)`.
- Outside a container, such as with `JSONEncoder`, the property encodes as plain `Data?`.

## Paging and counting

```swift
let page = try context.fetch(ToDo.self, where: #Predicate { !$0.done }, limit: 20, offset: 40)
page.indices            // 40..<60, the records' positions in the full results
try context.count(ToDo.self, where: #Predicate { $0.done })   // SELECT COUNT(*) when it translates
```

A page is a read-only `RecordSlice`, read straight from SQL when the predicate translates.

## Change tracking

Every save keeps a record's bookkeeping beside it, out of the record's own properties:

```swift
let meta = try context.metadata(ToDo.self, id: todo.id)
meta?.version     // goes up once per save that changes the record's values, links or order
meta?.modified    // when that save happened

let token = try context.changeToken
// …later
for change in try context.changes(since: token) {
    change.recordType, change.id, change.kind   // "ToDo", its UUID, .save or .delete
}
```

- The log keeps one entry per record, so editing a record moves its entry rather than adding one. It
  grows only with the number of records, plus one entry per deleted record.
- `pruneChanges(before:)` removes deleted records' entries older than a token.
- Each record also has a tag, opaque data such as a `CKRecord`'s archived system fields, which
  `metadata(_:id:)?.tag` reads. Storing a tag never changes the version, and fetches never load tags.
- Reading changes or metadata saves the context's pending edits first.

These are the pieces a sync layer such as `CKSyncEngine` needs: what changed, what was deleted, and the
server's change tag for each record. Within this package, a sync layer also gets `setTag(_:for:id:)`,
`applyingSyncedChanges(_:)`, whose writes are never logged and so never sent back, and a small key-value
store (`syncValue(forKey:)`) for its engine state and change token.

The main context refreshes its views after any change committed to its container, including ones
written by a background context or a sync layer.

## SwiftUI

```swift
@main
struct ToDoApp: App {
    let container = try! RecordContainer()   // the default zone

    var body: some Scene {
        WindowGroup { ContentView().recordContainer(container) }
    }
}

struct ContentView: View {
    @Records var todos: [ToDo]

    var body: some View {
        List($todos, editActions: .all) { $todo in
            TextField("Title", text: $todo.title)
        }
    }
}
```

Without a container in the environment, `@Records` uses the default zone's shared container.
`@Records("drafts")` reads another zone, through the environment's container if it belongs to that
zone and otherwise through `RecordContainer.shared(_:)`, which returns the most recently opened
container for a zone's file. Either way it reads and writes through that container's `mainContext`.

`$todos` is a real `Binding<[ToDo]>`. Writes insert, update and delete through the main context,
which batches them into one transaction once edits pause for `autosaveDelay` (half a second by
default). The array's order is stored, so moves persist, and records always come back in that order.
Sort a copy to display them another way.

Typing into a bound field stays cheap: the context keeps only the latest pending change to each
record, the container writes only rows, links and positions that actually changed, and a `@Records`
view whose own edit was saved keeps its cached array instead of fetching again.

## Requirements

iOS 17, macOS 14, Swift 6. The package also builds on Linux with `libsqlite3-dev`, which is how CI and
the tests run outside Xcode.
