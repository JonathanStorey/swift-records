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

## Storing and querying

```swift
let container = try RecordContainer()                // the default zone

try container.save(todo)                             // saves the ToDo, its Person and every Note
let open = try container.fetch(ToDo.self,
                           where: #Predicate { !$0.done },
                           sortBy: [SortDescriptor(\.title)])
let parents = try container.fetch(ToDo.self, ids: note.todos)
try container.delete(todo)
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
let greeted = try container.fetch(ToDo.self, where: #Predicate { todo in
    todo.notes.contains { $0.text == "hello world" }
})
```

Anything else is evaluated in memory, so every predicate works.

## Relationships

- Any property whose type is a `@Record`, an optional `@Record` or an array of them is a relationship.
  It is stored in a join table named `Owner.property` that keeps the order of both sides.
- Delete rules: `.cascade` (the default, like a nested struct) and `.none`, which unlinks and keeps them. Cascade only
  deletes records nothing else still references, and it also applies when a record is removed from
  an array.
- An inverse, `@Reference(from:)`, holds the owners' IDs in order. Loading full records eagerly would
  recurse forever with value types, so fetch them with `container.fetch(_:ids:)`. Reordering the IDs and
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

try container.save(Photo(image: jpeg))
let photo = try container.fetch(Photo.self).first
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
let page = try container.fetch(ToDo.self, where: #Predicate { !$0.done }, limit: 20, offset: 40)
page.indices            // 40..<60, the records' positions in the full results
try container.count(ToDo.self, where: #Predicate { $0.done })   // SELECT COUNT(*) when it translates
```

A page is a read-only `RecordSlice`. Without sort descriptors it is read straight from SQL.

## Change tracking

Every save keeps a record's bookkeeping beside it, out of the record's own properties:

```swift
let meta = try container.metadata(ToDo.self, id: todo.id)
meta?.version     // goes up once per save that changes the record's values, links or order
meta?.modified    // when that save happened

let token = try container.changeToken
// …later
for change in try container.changes(since: token) {
    change.recordType, change.id, change.kind   // "ToDo", its UUID, .save or .delete
}
```

- The log keeps one entry per record, so editing a record moves its entry rather than adding one. It
  grows only with the number of records, plus one entry per deleted record.
- `pruneChanges(before:)` removes deleted records' entries older than a token.
- `setTag(_:for:id:)` stores opaque data with a record, such as a `CKRecord`'s archived system fields,
  without changing its version. `metadata(_:id:)?.tag` reads it back. Fetches never load tags.

These are the pieces a sync layer such as `CKSyncEngine` needs: what changed, what was deleted, and the
server's change tag for each record. Within this package, a sync layer also gets
`applyingSyncedChanges(_:)`, whose writes are never logged and so never sent back, and a small key-value
store (`syncValue(forKey:)`) for its engine state and change token.

A `RecordsContext` refreshes its views after any change committed to its container, including ones
written by a background task or a sync layer.

## SwiftUI

```swift
@main
struct ToDoApp: App {
    @State private var context = try! RecordsContext()   // the default zone

    var body: some Scene {
        WindowGroup { ContentView().recordsContext(context) }
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

Without a context in the environment, `@Records` uses the default zone's shared context.
`@Records("drafts")` reads another zone, through the environment's context if it belongs to that zone
and otherwise through `RecordsContext.shared(_:)`.

`$todos` is a real `Binding<[ToDo]>`. Writes insert, update and delete through `RecordsContext`,
which batches them into one transaction once edits pause for `autosaveDelay` (half a second by
default). Without sort descriptors, the array's order is stored, so moves persist.

Typing into a bound field stays cheap: the context keeps only the latest pending change to each
record, the container writes only rows, links and positions that actually changed, and a `@Records`
view whose own edit was saved keeps its cached array instead of fetching again.

## Requirements

iOS 17, macOS 14, Swift 6. The package also builds on Linux with `libsqlite3-dev`, which is how CI and
the tests run outside Xcode.
