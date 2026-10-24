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
    var notes: [Note] = []                 // to-many, order kept
    var labels: [Label] = []               // many-to-many
    var tags: [String] = []                // plain Codable, stored as JSON
}

@Record
struct Note {
    var id = UUID()
    var text: String
    @Reference(to: \ToDo.notes, action: .deleteSelf) var todo: ToDo.ID?   // its one parent
}

@Record
struct Label {
    var id = UUID()
    var name: String
    @Reference(from: \ToDo.labels) var todoIDs: Set<ToDo.ID>             // inverse, read-only
}
```

Every record's `id` is a `UUID`, so records created on different devices never collide. IDs are
stored as 16-byte blobs, which keeps primary keys and join tables compact.

## Containers and contexts

The shape follows SwiftData. A `RecordContainer` owns a folder of zone files, their assets and the
schema. You read and write through a context.

```swift
let container = try RecordContainer()                // Application Support/Records
let context = container.mainContext                  // one per container, on the main actor

context.insert(todo)                                 // a new ToDo, its Person and every Note
context.insert(edited)                               // replaces the record with the same ID
let open = try context.fetch(RecordDescriptor<ToDo>(predicate: #Predicate { !$0.done }))
let todo: ToDo? = try context.record(for: id)        // or record(ToDo.self, for: id)
context.delete(todo)
context.delete(record: ToDo.self, where: #Predicate { $0.done })
try context.save()                                   // or let autosave commit once edits pause
```

The names follow `ModelContext`. `insert(_:)` adds a record, or replaces the one with the same ID, as
SwiftData does for a unique ID. `record(for:)` returns a
record with any unsaved change and never saves, so a view can call it while it updates.

Changes live in memory until `save()` commits them to disk, which autosave does once edits pause for
`autosaveDelay`. Until then `rollback()` discards them, and `unsavedChanges` counts them. Every fetch
saves first, so results include your own edits. Records come back in a descriptor's `sortBy` order, and
by ID where that leaves a tie or when there's none. ID order is stable but carries no meaning. A
`@Timestamp(.created)` property gives you creation order, and a property of your own can hold a manual
order. `transaction { }` runs a block
and saves its changes in one commit, or rolls back just that block's changes if it throws.

`save()` also comes in an `async` version, which commits off the main actor and suspends instead of
blocking while a background import holds the file. Autosave always uses it. For fetches off the main
actor, use a background context.

If a save fails, its changes stay pending so you can fix the cause and save again, or discard them
with `rollback()`. A failed autosave sets `lastSaveError`. If the failure can pass, such as a full disk
or a widget writing at the same moment, its changes stay pending and autosave tries again after a
second, then two, up to a minute. Otherwise it rolls back, since retrying would fail the same way.
Every error the library throws is a `RecordsError`, such as `.invalidValue(type:property:)` for a NaN.
A stored record that no longer decodes, such as after a property changed type, is left out of fetches
rather than failing them, and `status` shows `.failed(.incompatibleRecord(type:id:))` until it decodes
again or is deleted.

`context.status` says where changes stand: `saving`, `saved` or `failed(_:)` for a local container, plus
`syncing`, `offline` and `signedOut` with a sync provider. It is observable, so a view can show it.

For work off the main actor, such as an import, use a background context. Its saves commit right away,
`transaction(_:)` groups several into one commit, and the main context refreshes after each commit.

```swift
try await container.performBackgroundTask { context in
    for start in stride(from: 0, to: downloaded.count, by: 200) {
        let batch = Array(downloaded[start..<min(start + 200, downloaded.count)])
        try context.transaction { try context.insert(batch) }
    }
}
```

The container serializes access to its file, so the main context waits while a transaction runs. Keep
each transaction to a few hundred records and split a large import into several, as above.

`container.deleteAllData()` removes every record, asset file and piece of sync state in the default
zone and discards the main context's pending changes there, and `deleteAllData(in: "drafts")` does the
same for another zone, for signing out or resetting the app. It touches this
device only: a sync server keeps its copy, and the next sign-in brings it back.

Listing the record types up front, as SwiftData's `ModelContainer(for:)` does, creates their tables and
applies renames and indexes when the container opens. Types reached through relationships are found
automatically. It's optional for a local container and required for sync.

Registering also checks the types before anything is written, and throws
`RecordsError.invalidSchema(type:reason:)` for a setup mistake that would mix up data:
- two types stored under one name
- a relationship whose target has neither a `@Reference(to:)` nor a `@Reference(from:)` for it
- a reference or inverse whose key path isn't a relationship back to its type
- an `@Renamed` old name that is still a property's name, or is shared by two properties
- with a sync provider, a type or property name a server can't take: it must be letters, digits and
  underscores, starting with a letter

```swift
let container = try RecordContainer(for: [ToDo.self])
```

## Zones

A container is a folder, and a `Zone` is a database file in it. The context's `zone` decides where saves,
deletes and fetches go. It starts as `.default`.

```swift
let container = try RecordContainer()     // Application Support/Records
let context = container.mainContext

context.insert(recipe)                    // _default.sqlite
context.zone = "drafts"
context.insert(draft)                     // drafts.sqlite, opened on first use
let drafts = try context.fetch(Recipe.self)
context.zone = .default                   // back to the default zone

try await container.performBackgroundTask(in: "drafts") { try $0.insert(imported) }
context.zone = .inMemory                  // never written to disk, never synced
context.zone = .localOnly                 // _local.sqlite, never synced
let scratch = try RecordContainer(inMemory: true)   // every zone lives in memory
```

Switching zones refetches every `@Records` view that doesn't name a zone of its own. Pending changes stay
with the zone they were made in, and a save commits each zone it touches in a transaction of its own.
Relationships stay within one zone, and the same record type can be stored in several.

A zone name is lowercased, then must be 1 to 64 letters, digits, `-` or `_`, starting with a letter, so
`"Drafts"` and `"drafts"` are the same zone. A string literal with an invalid name stops the app, and
`try Zone(name)` throws for names that come from elsewhere. Names starting with an underscore are reserved
for `.default`, `.inMemory` and `.localOnly`.

Zone files are local to the device unless the container syncs. They are included in the device's own
backups (iCloud or computer, whichever the user chose) and in phone-to-phone transfers. On macOS the
folder sits inside one named for the app's bundle identifier.

To share a zone with a widget or other app extension, open it in the App Group's container from both:

```swift
let directory = RecordContainer.directory(appGroup: "group.com.example.todo")!
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

Anything else is evaluated in memory, so every predicate works. When only some of a predicate's `&&`
terms translate, those run as SQL to narrow the rows and only the rest is checked in memory.

## Changing a record type

- **New properties** read their declared default from rows saved before they existed, such as
  `var servings = 2`. Optionals read as `nil`. A new non-optional property needs a default.
- **Renamed properties** keep their values with `@Renamed(from: "minutes") var duration = 0`. The
  column (or a relationship's join table) is renamed the first time the container uses the type.
- **Renamed types** keep their data with `@Record("Recipe")`, which fixes the stored name. A
  type nested inside another needs one, since its simple name could clash.
- A property renamed more than once lists every earlier name: `@Renamed(from: "minutes", "time")`.
- `@Indexed` adds an index to a property that predicates compare, and changes nothing about encoding.
- `@Reference`, `@Renamed`, `@Indexed` and `@Timestamp` are read by `@Record`, so they only mean
  something on a `@Record` struct's properties. Elsewhere the compiler warns that they have no effect.
- Generic structs can't be records, since each specialization would need its own fixed name.
- `rowid`, `oid` and `_rowid_` are SQLite's names for a row's ID, and the macro rejects them as
  property names.

Values are stored exactly: a `UInt64` above `Int64.max` round-trips, strings keep embedded NUL
characters, and sets and dictionaries are written in a stable order so re-saving one never counts as
an edit. A `Double` or `Float` that is NaN can't be stored, so saving it throws.

## Relationships

Relationships follow CloudKit's model: the child says how it belongs. Any property whose type is a
`@Record`, an optional `@Record` or an array of them is a relationship, stored in a join table named
`Owner.property` that keeps the owner's order. Its target type declares one of two things for it.

**One parent: `@Reference(to:action:)`.** A note belongs to one to-do, a step to one recipe, a reply to
one comment. The child holds its parent's ID, which is a column you can query and set.

- Saving the parent sets each child in its array to point at it. Setting a child's reference and
  saving the child moves it to the end of its new parent's array, so you can link from either side.
- The action says what happens when the parent goes, named after `CKRecord.ReferenceAction`.
  `.deleteSelf` deletes the child when the parent is deleted, when it's removed from the array, or when
  its reference is cleared. `.none`, the default, keeps the child and clears its reference.
- Moving a child between two arrays in one save keeps it. A `.deleteSelf` child is only deleted if it
  ends the transaction without a parent.
- `#Predicate { $0.todo == todoID }` runs as SQL, and the reference column is indexed.
- A record with references to several parents, such as a `Membership` that belongs to a `Person` and a
  `Team`, declares one for each. That is how to give a many-to-many link properties of its own. Saving
  it through one parent's array never clears its reference to another.

**Several owners: `@Reference(from:)`.** A label can be on many to-dos. The inverse is a `Set` of the
owners' IDs, so name it for that, such as `todoIDs`.

- Deleting an owner, or removing the label from its array, only unlinks it.
- Loading full records would recurse forever with value types, so fetch the owners with a predicate,
  `#Predicate<ToDo> { ids.contains($0.id) }` on a local `let ids = label.todoIDs`, which runs as SQL.
- It is read-only, with no initial value: the container fills it from the owners' links, so link or
  unlink from the owner's side.
- `#Predicate { $0.todoIDs.contains(todo.id) }` runs as SQL, like `contains { }` on a forward
  relationship, so searches work at full speed in both directions.

Deleting any record removes it from every owner's relationship, so a deleted recipe leaves each
cookbook that held it. The container checks that every relationship's target declares one of these
when you register the types.

## Assets

Large data such as photos and audio belongs in an `@Asset` property, which stores its `Data?` as a
file beside the database instead of inside it.

```swift
@Record
struct Photo {
    var id = UUID()
    @Asset(fileExtension: "jpg") var image: Data? = nil
}

context.insert(Photo(image: jpeg))
let photo = try context.fetch(Photo.self).first
let url = photo?.$image.url      // the stored file, for AsyncImage, QuickLook or AVPlayer
let bytes = photo?.image         // read from disk on first access, then cached
```

- Fetching never reads asset files. The bytes load the first time the property is read, so prefer
  `$image.url` where a URL will do.
- Files live in a folder named after the database file, such as `Records/_default.assets/`, so they
  are included in device backups along with the zone.
- Assigning new data or `nil` removes the old file when the record is saved, and deleting a record
  (directly or by cascade) removes its files. Rolled-back transactions leave no files behind.
- To copy a large file in without loading it, assign `photo.$image = Asset(contentsOf: url)`.
- Outside a container, such as with `JSONEncoder`, the property encodes as plain `Data?`.

## Sorting

`RecordDescriptor` and `@Records` take Foundation's `SortDescriptor`, as `FetchDescriptor` and `@Query` do:

```swift
let latest = try context.fetch(RecordDescriptor<ToDo>(sortBy: [SortDescriptor(\.due, order: .reverse)]))
```

Sorting by a number or a date, optional or not, runs as SQL `ORDER BY`, so a sorted page reads only its
own rows. `nil` comes first in forward order, as `SortDescriptor` puts it. Any other sort runs in Swift
after the matches load. That includes strings, because `SortDescriptor` compares them the localized way
by default, which SQLite can't match. Records that tie on every descriptor come by ID.

## Paging and counting

```swift
let page = try context.fetch(RecordDescriptor<ToDo>(predicate: #Predicate { !$0.done }, fetchLimit: 20, fetchOffset: 40))
try context.fetchCount(RecordDescriptor<ToDo>(predicate: #Predicate { $0.done }))   // SELECT COUNT(*) when it translates
try context.fetchIdentifiers(RecordDescriptor<ToDo>())   // IDs only, without loading the records
```

`RecordDescriptor` mirrors SwiftData's `FetchDescriptor`. A page is read straight from SQL when the
predicate and sort translate.

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
Button("Save") { context.insert(draft); dismiss() }
    .disabled(!context.hasChanges(draft))
```

It counts the context's pending changes and related records, so editing a step marks its recipe as
changed, and undoing an edit makes it false again. A record the context has never saved is changed.
`@Timestamp` properties and inverses are left out, because the container sets them. It never saves, so
a view can call it while it updates, and each call costs one read by ID.

## Change tracking

Every save keeps a record's bookkeeping in one row of its own, in a separate table, so a record's table
holds only its ID and its properties:

```swift
let meta = try context.metadata(ToDo.self, id: todo.id)
meta?.version     // goes up once per save that changes the record's values or links
meta?.modified    // when that save happened
meta?.tag         // sync bookkeeping: the server's synced date for this copy, if any
```

Reading metadata saves the context's pending edits first. Storing a tag never changes the version,
and fetches never load tags. Files from version 0.3.0, which kept this in hidden columns beside each
record, aren't supported, so start 0.4.0 with a new file.

That row is also the change log, which is how sync knows what the server doesn't have yet, and it keeps
what sync needs for merging. A deleted record's row stays until the server acknowledges the deletion.
Besides record and link tables, a file holds just four internal tables: that bookkeeping, asset files,
relationship rules and sync state.

The main context refreshes its views after any change committed to its container, including ones
written by a background context or a sync provider.

## Sync

A `SyncProvider` keeps a zone in step with a server. Pass a closure when the container opens, and it's
called once for each zone as the zone opens, except `.inMemory` and `.localOnly`. Return a provider to sync that zone with its zone on the
server, or `nil` to keep it on the device. The same app code works with or without it: sync adds to
saving, it doesn't replace it.

```swift
let container = try RecordContainer(for: [ToDo.self], syncProvider: { zone in
    zone == "drafts" ? nil : MyProvider(zone: zone)     // keep drafts on the device
})

try await context.save()       // commits, then sends what the server doesn't have
try await context.refresh()    // also fetches the server's changes, for pull-to-refresh
```

The async `save()` and autosave send. The synchronous `save()` only commits, and its changes go with
the next send. `refresh()` throws only what leaves `status` at `failed`: offline and signed out aren't
errors, and changes wait on the device until they can go. `unsyncedChanges` counts the saved records
the server hasn't confirmed. It stays at 0 without a provider and grows while offline or signed out.

You can switch providers later, for example to a bigger server as traffic grows. Each provider has an
`identifier`, its type name by default, so return something like the server's URL when one type can reach
several servers. When a zone's provider identifier changes, the container treats the new server as empty:
it keeps every local record, uploads them all and downloads from the beginning, whatever `onAccountSwitch`
says, since a new server's user IDs needn't match the old one's.

The provider is transport only, so anyone can write one: a CloudKit provider, a central database or a
folder of files. Each call returns what happened, and the container drives it:

```swift
public protocol SyncProvider: AnyObject, Sendable {
    func userID() async throws -> String?
    func uploadRecordChanges(_ changes: [RecordChangeData]) async throws -> [UploadResult]
    func downloadRecordChanges(in zone: Zone, after cursor: Data?) async throws -> RecordDownload
    func uploadAssets(_ assets: [RecordAssetData]) async throws
    func downloadAsset(id: String, zone: Zone, into directory: URL) async throws -> URL
    func pushedChanges() -> AsyncStream<[Zone]>?      // optional, defaults to nil
}
```

The unit of sync is a whole record, `RecordChangeData`: `.save(id:zone:type:json:owner:synced:)` or
`.delete(id:zone:type:owner:synced:)`. The JSON reads like the record, with relationships as arrays of
IDs and assets as their file IDs. Nothing else is added. The server
stamps every accepted change with a strictly later `synced` date and returns it as `.synced(id:at:)`. An
upload carries the date of the copy it was edited from, and a server whose copy is newer answers
`.conflict` with that copy, which the container merges and sends again. A server can use the newest
`synced` date as its download cursor. Throw `SyncError.offline`, `.storageFull` or `.serverReset` when a
whole call fails.

A provider that hears about changes, such as from push notifications, returns a stream from
`pushedChanges()`. The container downloads each zone the stream names, so views update without a
refresh.

Assets travel on their own, in the background. `refresh()` syncs records only and returns once they're
stored. After each pass the container uploads files the server doesn't have and downloads the ones
received records point to, one file at a time. Until a file lands, its record's asset reads `nil` and
`$image.url` is `nil`, and views refresh when it arrives. A file that fails, such as one whose record
arrived before its upload finished, is tried again after the next pass. A file never changes once
stored, so an asset can't conflict, and each one is uploaded once.

```swift
if let progress = context.assetProgress {
    ProgressView(value: progress)    // 0 to 1 by file count, nil when nothing is moving
}
```

`publicZones` names zones everyone shares. Their records carry the user who created them as `owner`,
the server refuses changes from anyone else, signing out never deletes them, and they download without
an account.

Inverses aren't sent. The container owns the rules:

- **Conflicts merge.** When the server's copy and an unsent local edit meet, a property only one side
  changed keeps that change, using a snapshot of the record as last synced. Relationship lists merge
  item by item, so steps added on two devices both survive. Only a property both sides changed falls
  to `mergePolicy`, which defaults to the latest edit. A `@Timestamp(.modified)` property dates each copy
  when the type has one. Otherwise the server's copy dates from when the server accepted it, so an edit
  made offline counts from when it uploaded. `.serverWins`, `.localWins` and `.latestWins`
  settle whole records instead.
- **A delete beats an edit made elsewhere**, unless the policy is `.localWins` or `.serverWins`. Under
  `.mergeProperties(otherwise:)`, its `otherwise` policy decides.
- **Arrival order doesn't matter.** A record can arrive before the records it links to, and its links
  appear when they do.
- **A child's reference decides where it belongs.** If a parent's list and a child's reference
  disagree, such as when the child moved on another device, the child goes to the parent it names, and
  the parent's list only sets the order. A child the list doesn't have yet goes at the end.
- **Newer app versions are safe.** Fields this version doesn't know are kept and sent back with the
  next edit, and `@Renamed` properties read their old names. A record that won't decode is kept and
  tried again after an update.
- **Accounts have policies.** `onSignOut` (keep local data by default), `onAccountSwitch` (delete) and
  `onServerReset` (keep and upload again) decide what an account change does.

### CloudKit records

On Apple platforms a change converts to a `CKRecord` and back, field for field, so a CloudKit provider
stores records exactly as CloudKit expects:

```swift
let record = try container.ckRecord(for: change, in: zoneID, base: lastServerCopy)   // nil for a deletion
let (change, assets) = try container.change(from: record, zone: zone)
```

| Record | CKRecord |
| --- | --- |
| `id`, type, zone | `recordName` (the `uuidString`), `recordType`, `zoneID` |
| `String`, numbers, `Bool`, `Date`, `Data` | fields of the same name |
| `[String]`, number and `[Date]` arrays | CloudKit lists |
| any other `Codable` value | its JSON as `Data` |
| `var notes: [Note]` | the notes' record names in order, as a `[String]`, never forward references |
| a child's `@Reference(to:action:)` | a `CKRecord.Reference` with that action |
| `@Asset` | a `CKAsset` |
| inverses, `@Timestamp(.synced)` | nothing: they're rebuilt locally |

Each child is its own `CKRecord`, and locally it still appears nested in its parent's array. Pass the
server's last copy as `base`, such as one rebuilt from its encoded system fields, so a save carries its
change tag. Coming back, `modificationDate` is the `synced` date, and in a public zone the creator is the
owner. Downloaded asset files are named by their contents, and `change(from:zone:)` returns them so
`downloadAsset(id:zone:into:)` can hand them over. A server deletion converts with
`deletion(of:type:zone:)`.

### Syncing through iCloud files

`FileSyncProvider` syncs through a folder, and the system copies the folder between devices. No server
is needed.

```swift
let container = try RecordContainer(for: [Recipe.self], syncProvider: { _ in FileSyncProvider() })
```

| Location | Folder |
| --- | --- |
| `.iCloud` (default) | The app's iCloud container, hidden from the Files app |
| `.iCloudDrive` | The container's `Documents` folder, visible in Files and iCloud Drive |
| `.appGroup("group.com.example")` | An App Group's folder, shared with extensions on one device |
| `.applicationSupport` | Application Support on this device, for tests and the simulator |
| `.other(directory: url)` | Any folder |

Each record is one readable JSON file at `Records/<zone>/<type>/<id>.json`, and assets are plain files
in `Records/<zone>/_assets/`. Deletions stay behind as small files so devices that sync later hear of
them. Downloads remember every file they've seen rather than a time, so devices whose clocks disagree
can't miss changes. Deleting a zone's folder counts as a server reset. iCloud needs the iCloud
capability with iCloud Documents on, and while the person is signed out, `status` is `.signedOut`.
For `.iCloudDrive`, add `NSUbiquitousContainers` to Info.plist so the folder shows in Files.

Other devices' changes arrive on their own through `pushedChanges()`. In iCloud an `NSMetadataQuery`
watches the folder, including when another device's file finishes downloading. Other folders are
checked every `watchInterval` (10 seconds by default, `nil` to turn it off). When two devices write a
record file at once, iCloud keeps both versions, and `NSFileVersion` settles them by keeping the copy
with the later `synced` date as a whole record.

## SwiftUI

```swift
@main
struct ToDoApp: App {
    let container = try! RecordContainer()   // Application Support/Records

    var body: some Scene {
        WindowGroup { ContentView().recordContainer(container) }
    }
}

struct ContentView: View {
    @Records var todos: [ToDo]
    @Environment(\.recordContext) private var context

    var body: some View {
        List($todos, editActions: .all) { $todo in
            TextField("Title", text: $todo.title)
        }
        .toolbar {
            Button("Add") { $todos.wrappedValue.append(ToDo(title: "New")) }   // shows at once
            Button("Save") { try? context.save() }
        }
    }
}
```

As with SwiftData, `.recordContainer(_:)` puts the container in the environment, and
`@Environment(\.recordContext)` reads its main context, the one `@Records` writes through. A bare
`@Records var todos: [ToDo]` takes no arguments, so `ContentView()` needs none either.

Like `@Query`, `@Records` sorts by one property or by a list of descriptors:

```swift
@Records(sort: \.title) var todos: [ToDo]
@Records(filter: #Predicate<ToDo> { !$0.done }, sort: [SortDescriptor(\.priority, order: .reverse)]) var open: [ToDo]
```

`@Records(filter:sort:animation:)` animates the list's changes, including ones from a background import.

`@Records` also loads records by ID, and keeps them current the same way:

```swift
@Records(ids: recipe.cookbookIDs) var cookbooks: [Cookbook]   // an inverse's owners, sorted by ID
@Records(id: recipeID) var recipe: Recipe?                   // nil once the recipe is deleted
```

Writing a record to `$recipe` saves it, and writing `nil` deletes it. The wrapper is bound to one ID, so
writing a record with a different ID is a programmer error: it asserts in debug builds and is ignored in
release builds. A list works differently. Assigning a different record at an index replaces the old one,
which is deleted along with its cascades, while the new one brings only its own references.

`@Records` reads and writes through the main context of the environment's container, or without one, the
most recently opened container on the default folder. It follows `context.zone`, so setting the zone
switches every list at once. `@Records("pantry")` pins a property to one zone instead, and
`@Records(.default)` to the default zone.

Like `@Query`, `@Records` also takes a descriptor, which can limit how many records a view holds:
`@Records(RecordDescriptor<ToDo>(predicate: #Predicate { !$0.done }, fetchLimit: 20)) var firstOpen: [ToDo]`.
Unsaved new records still count toward it, so the view never shows more than the limit. Pass a zone first,
`@Records("pantry", descriptor)`, to pin it.

`$todos` is a real `Binding<[ToDo]>`. Writes insert, update and delete through the main context,
which batches them into one transaction once edits pause for `autosaveDelay` (half a second by
default). Every view reading the same records shows the change at once, before it saves, and so do changes
made through `@Environment(\.recordContext)`, such as `context.insert(todo)`. A new or edited record
takes its place in the list's sort, a filtered list drops records its filter rejects, and a rollback takes
them back out. Deletes by predicate hide their matches at once too. The array's order isn't stored, so a
move through the binding changes nothing.

Typing into a bound field stays cheap: the context keeps only the latest pending change to each
record, the container writes only rows and links that actually changed, and a `@Records`
view whose own edit was saved keeps its cached array instead of fetching again.

## Benchmarks

The `Benchmarks` program times the heaviest operations on a store of recipes with five nested steps
each, written to files on disk and synced through a server in memory, so sync timings measure the local
database rather than a network:

```
swift run -c release Benchmarks                                       # 10,000 recipes, 60,000 records
swift run -c release Benchmarks --recipes 50000                       # a larger store
swift run -c release Benchmarks --save before.json                    # keep a run
swift run -c release Benchmarks --compare before.json                 # each timing's change from it
```

It covers a background import, saving on the main context, fetching every record with its nested
children, fetching by ID, indexed and unindexed predicates, counting, paging, sorting, editing, reordering
children, cascading deletes, uploading and downloading a whole store, syncing 100 edits into a large
store, and resyncing everything with a new server. Each step checks its result, so a run also fails
when an operation goes wrong at scale. `Benchmarks/linux-baseline.json` is a run in the `swift:6.1-noble` image that CI uses, on a cloud VM. Timings on a shared VM vary by about 10% between runs.

Some timings from that run, for 60,000 records:

| Operation | Time |
| --- | --- |
| Import in saves of 500 | 7.5 s |
| Fetch every recipe with its steps | 2.4 s |
| Fetch 1,000 recipes by ID | 0.33 s |
| Edit and save 1,000 recipes | 0.31 s |
| Delete 1,000 recipes and their steps | 0.55 s |
| Upload the whole store | 8.7 s |
| Download the whole store to a new device | 11.8 s |
| Sync 100 edits from a large store | 17 ms |

## Requirements

iOS 17, macOS 14, Swift 6. The package also builds on Linux with `libsqlite3-dev`, which is how CI and
the tests run outside Xcode.
