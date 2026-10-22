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
    @Reference(from: \ToDo.notes) var todoIDs: Set<ToDo.ID>  // inverse, read-only
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
let parents = try context.fetch(ToDo.self, ids: note.todoIDs)
context.delete(todo)
context.delete(ToDo.self, where: #Predicate { $0.done })   // or delete(ToDo.self, id: id)
try context.save()                                   // or let autosave commit once edits pause
```

The main context collects changes and commits them together, either when you call `save()` or
automatically once edits pause for `autosaveDelay`. Every fetch saves first, so results include your
own edits. Records come back in their stored order. To show them in another order, sort a copy.

Saving and fetching also come in `async` versions, which do the database work off the main actor and
suspend instead of blocking while a background import holds the file. Autosave always uses them. In
async code the compiler picks them, so add `await`. The synchronous versions stay for everything else.

```swift
try await context.save()
let open = try await context.fetch(ToDo.self, where: #Predicate { !$0.done })
```

If a save fails, its changes stay pending so you can fix the cause and save again, or discard them
with `rollback()`. A failed autosave sets `lastSaveError` and rolls back, since nothing could retry it.
Every error the library throws is a `RecordsError`, such as `.invalidValue(type:property:)` for a NaN.

`context.status` says where changes stand: `saving`, `saved` or `failed(_:)` for a local container, plus
`syncing`, `offline` and `signedOut` with a sync provider. It is observable, so a view can show it.

For work off the main actor, such as an import, use a background context. Its saves commit right away,
`transaction(_:)` groups several into one commit, and the main context refreshes after each commit.

```swift
try await container.performBackgroundTask { context in
    for start in stride(from: 0, to: downloaded.count, by: 200) {
        let batch = Array(downloaded[start..<min(start + 200, downloaded.count)])
        try context.transaction { try context.save(batch) }
    }
}
```

The container serializes access to its file, so the main context waits while a transaction runs. Keep
each transaction to a few hundred records and split a large import into several, as above.

`container.deleteAllData()` removes every record, asset file and piece of sync state in the zone and
discards the main context's pending changes, for signing out or resetting the app. It touches this
device only: a sync server keeps its copy, and the next sign-in brings it back.

Listing the record types up front, as SwiftData's `ModelContainer(for:)` does, creates their tables and
applies renames and indexes when the container opens. Types reached through relationships are found
automatically. It's optional for a local container and required for sync.

Registering also checks the types before anything is written, and throws
`RecordsError.invalidSchema(type:reason:)` for a setup mistake that would mix up data:
- two types stored under one name
- an inverse whose key path isn't a relationship back to its type
- an `@Renamed` old name that is still a property's name, or is shared by two properties
- with a sync provider, a type or property name a server can't take: it must be letters, digits and
  underscores, starting with a letter

```swift
let container = try RecordContainer(for: [ToDo.self, Folder.self])
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

To share a zone with a widget or other app extension, open it in the App Group's container from both:

```swift
let directory = Zone.directory(appGroup: "group.com.example.todo")!
let container = try RecordContainer(directory: directory)
```

Files use SQLite's write-ahead log, so the app and an extension can read while the other writes. Every
save and fetch sees the other process's latest commits. Views refresh for them when the app becomes
active, or right away when you call `context.refresh()`.
Containers opened on the same file within one process share a connection, so each sees the other's
changes and their main contexts refresh together.

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
- **Renamed types** keep their data with `@Record(name: "Recipe")`, which fixes the stored name. A
  type nested inside another needs one, since its simple name could clash.
- A property renamed more than once lists every earlier name: `@Renamed(from: "minutes", "time")`.
- `@Indexed` adds an index to a property that predicates compare, and changes nothing about encoding.
- `@Reference`, `@Renamed`, `@Indexed` and `@Timestamp` are read by `@Record`, so they only mean
  something on a `@Record` struct's properties. Elsewhere the compiler warns that they have no effect.
- Generic structs can't be records, since each specialization would need its own fixed name.
- `_position`, `_version`, `_modified`, `_tag` and `rowid` are reserved for bookkeeping, and the macro
  rejects them as property names.

Values are stored exactly: a `UInt64` above `Int64.max` round-trips, strings keep embedded NUL
characters, and sets and dictionaries are written in a stable order so re-saving one never counts as
an edit. A `Double` or `Float` that is NaN can't be stored, so saving it throws.

## Relationships

- Any property whose type is a `@Record`, an optional `@Record` or an array of them is a relationship.
  It is stored in a join table named `Owner.property` that keeps the owner's order. A forward
  relationship is fully readable and writable, and it is how you link and unlink records.
- Delete rules: `.cascade` (the default, like a nested struct) and `.none`, which unlinks and keeps them. Cascade only
  deletes records nothing else still references, and it also applies when a record is removed from
  an array.
- An inverse, `@Reference(from:)`, is a `Set` of the owners' IDs, so name it for that, such as `todoIDs`. Loading full records would recurse
  forever with value types, so fetch them with `context.fetch(_:ids:)`, which returns them in stored
  order. It is read-only, with no initial value: the container fills it from the owners' links, so
  link or unlink from the owner's side.
- Deleting a record removes it from every owner's relationship, so a deleted recipe leaves each
  cookbook that held it.
- `#Predicate { $0.todoIDs.contains(todo.id) }` on an inverse runs as SQL, like `contains { }` on a forward
  relationship, so searches work at full speed in both directions.

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

## Timestamps

`@Timestamp` marks a `Date?` property that the container sets and your code can only read:

```swift
@Record
struct Journal {
    var id = UUID()
    var text: String
    @Timestamp(.created) var created: Date?    // stamped on the first save
    @Timestamp(.modified) var modified: Date?  // stamped on each save that changes the record
    @Timestamp(.synced) var synced: Date?      // nil while the server lacks this version
}
```

`.created` and `.modified` are stored and synced like other properties, so they work in predicates
and every device agrees on them. A save that changes nothing leaves `modified` alone. `.synced` is this
device's view of the server: when it acknowledged the record as it is now, or `nil` while there are
changes it doesn't have, so a list can show which rows are still waiting. It isn't stored or sent, and
a predicate on it runs in memory. A bare `@Timestamp` means `.modified`.

## Unsaved edits

`context.hasChanges(record)` says whether a copy of a record differs from the one the context
holds, which suits an edit sheet that keeps a draft in `@State`:

```swift
Button("Save") { context.save(draft); dismiss() }
    .disabled(!context.hasChanges(draft))
```

It counts the context's pending changes and related records, so editing a step marks its recipe as
changed, and undoing an edit makes it false again. A record the context has never saved is changed.
`@Timestamp` properties and inverses are left out, because the container sets them. It never saves, so
a view can call it while it updates, and each call costs one read by ID.

## Change tracking

Every save keeps a record's bookkeeping beside it, out of the record's own properties:

```swift
let meta = try context.metadata(ToDo.self, id: todo.id)
meta?.version     // goes up once per save that changes the record's values, links or order
meta?.modified    // when that save happened
meta?.tag         // the sync server's opaque tag, if any
```

Reading metadata saves the context's pending edits first. Storing a tag never changes the version,
and fetches never load tags.

Behind this sits a change log with one entry per record, which is how sync knows what the server
doesn't have yet. A deleted record's entry stays until the server acknowledges the deletion.

The main context refreshes its views after any change committed to its container, including ones
written by a background context or a sync provider.

## Sync

A `SyncProvider` keeps a zone in step with a server. Pass one when the container opens. The same app
code works with or without it: sync adds to saving, it doesn't replace it.

```swift
let container = try RecordContainer(for: [ToDo.self], syncProvider: provider)

try await context.save()       // commits, then sends what the server doesn't have
try await context.refresh()    // also fetches the server's changes, for pull-to-refresh
```

The async `save()` and autosave send. The synchronous `save()` only commits, and its changes go with
the next send. `refresh()` throws only what leaves `status` at `failed`: offline and signed out aren't
errors, and changes wait on the device until they can go.

The provider is transport only. It has three requirements, `open(state:report:)`, `send(_:)` and
`fetch()`, and answers through `SyncEvent`s such as `.received`, `.sent` and `.accountChanged`. Records
cross as `SyncRecord`s holding standard types, so anyone can write a provider. The container owns the
rules:

- **Conflicts merge.** When the server's copy and an unsent local edit meet, a property only one side
  changed keeps that change, using a snapshot of the record as last synced. Relationship lists merge
  item by item, so steps added on two devices both survive. Only a property both sides changed falls
  to `mergePolicy`, which defaults to the latest edit. `.serverWins`, `.localWins` and `.latestWins`
  settle whole records instead.
- **A delete beats an edit made elsewhere**, unless the policy is `.localWins` or `.serverWins`.
- **Order doesn't matter.** A record can arrive before the records it links to, and its links appear
  when they do.
- **Newer app versions are safe.** Fields this version doesn't know are kept and sent back with the
  next edit, and `@Renamed` properties read their old names. A record that won't decode is kept and
  tried again after an update.
- **Accounts have policies.** `onSignOut` (keep local data by default), `onAccountSwitch` (delete) and
  `onServerReset` (keep and upload again) decide what an account change does.

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

`@Records(filter:animation:)` animates the list's changes, including ones from a background import.

`@Records` also loads records by ID, and keeps them current the same way:

```swift
@Records(ids: recipe.cookbookIDs) var cookbooks: [Cookbook]   // an inverse's owners, in stored order
@Records(id: recipeID) var recipe: Recipe?                   // nil once the recipe is deleted
```

Writing a record to `$recipe` saves it, and writing `nil` deletes it. The wrapper is bound to one ID, so
writing a record with a different ID is a programmer error: it asserts in debug builds and is ignored in
release builds. A list works differently. Assigning a different record at an index replaces the old one,
which is deleted along with its cascades, while the new one brings only its own references.

Without a container in the environment, `@Records` uses the default zone's shared container.
`@Records("drafts")` reads another zone, through the environment's container if it belongs to that
zone and otherwise through `RecordContainer.shared(_:)`, which returns the most recently opened
container for a zone's file. Either way it reads and writes through that container's `mainContext`.

`$todos` is a real `Binding<[ToDo]>`. Writes insert, update and delete through the main context,
which batches them into one transaction once edits pause for `autosaveDelay` (half a second by
default). The array's order is stored, so moves persist, and records always come back in that order.
A filtered list reorders only its own records within the slots they already hold, leaving the rest in
place. Sort a copy to display them another way.

Typing into a bound field stays cheap: the context keeps only the latest pending change to each
record, the container writes only rows, links and positions that actually changed, and a `@Records`
view whose own edit was saved keeps its cached array instead of fetching again.

## Requirements

iOS 17, macOS 14, Swift 6. The package also builds on Linux with `libsqlite3-dev`, which is how CI and
the tests run outside Xcode.
