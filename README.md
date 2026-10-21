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
    @Reference(deleteRule: .nullify) var notes: [Note] = []  // to-many, order kept
    var tags: [String] = []                              // plain Codable, stored as JSON
}

@Record
struct Note {
    var id = UUID()
    var text: String
    @Reference(from: \ToDo.notes) var todos: [ToDo.ID] = []  // inverse, order kept
}
```

## Storing and querying

```swift
let store = try RecordStore()                    // the default zone

try store.save(todo)                             // saves the ToDo, its Person and every Note
let open = try store.fetch(ToDo.self,
                           where: #Predicate { !$0.done },
                           sortBy: [SortDescriptor(\.title)])
let parents = try store.fetch(ToDo.self, ids: note.todos)
try store.delete(todo)
```

## Zones

A zone is a named database file. The name is the file name without its extension.

```swift
extension Zone {
    static let drafts: Zone = "drafts"
}

let main = try RecordStore()                     // Application Support/Records/default.sqlite
let drafts = try RecordStore(zone: .drafts)      // Application Support/Records/drafts.sqlite
let scratch = try RecordStore(zone: .inMemory)   // nothing on disk
```

Zone files are local to the device. The `Records` folder is excluded from iCloud and computer backups,
so its data is not restored to a new device. On macOS the folder sits inside one named for the
app's bundle identifier. Relationships stay within one zone, and the same record type can be stored
in several zones. To open a file somewhere else, use `RecordStore(url:)`.

## Queries

Simple predicates on a record's own properties run as SQL: `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`,
`||`, `!`, `nil` checks, `[values].contains(\.property)`, `String.contains` (iOS 18 / macOS 15) and
`localizedStandardContains`. Anything else is evaluated in memory, so every predicate works.

## Relationships

- Any property whose type is a `@Record`, an optional `@Record` or an array of them is a relationship.
  It is stored in a join table named `Owner.property` that keeps the order of both sides.
- Delete rules: `.cascade` (the default, like a nested struct), `.nullify` and `.deny`. Cascade only
  deletes records nothing else still references, and it also applies when a record is removed from
  an array.
- An inverse, `@Reference(from:)`, holds the owners' IDs in order. Loading full records eagerly would
  recurse forever with value types, so fetch them with `store.fetch(_:ids:)`. Reordering the IDs and
  saving persists the new order.

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

`$todos` is a real `Binding<[ToDo]>`. Writes insert, update and delete through `RecordsContext`,
which batches them into one transaction on the next turn of the main actor. Without sort
descriptors, the array's order is stored, so moves persist.

## Requirements

iOS 17, macOS 14, Swift 6. The package also builds on Linux with `libsqlite3-dev`, which is how CI and
the tests run outside Xcode.
