# swift-records

Codable records that live in a local SQLite store and, on Apple platforms,
sync with CloudKit. Built on
[swift-versioning](https://github.com/JonathanStorey/swift-versioning)'s
schemas and merges.

## Installation

```swift
.package(url: "https://github.com/JonathanStorey/swift-records", branch: "main")
```

```swift
.product(name: "SwiftRecords", package: "swift-records")
```

```swift
import SwiftRecords
```

## Platforms

The property wrappers, values and `RecordContainer` build everywhere,
Linux included. The CloudKit encoder, decoder and sync live in
`Sources/SwiftRecords/CloudKit` and compile only where CloudKit exists.

## CloudKit records

### Record IDs

`RecordID<Record>` is where a record lives: its name, its zone, and the
zone's owner. It is everything needed to find the record again.

```swift
let folder = try RecordID(folder, zone: "Notes")          // an Identifiable folder
let page = try RecordID(page, id: \.slug, zone: "Pages")   // a plain struct
```

The name is the record's `UUID` id, or the type and any other id, as in
`Page:intro`, the same name the record is saved under. An id with characters
other than ASCII letters, digits, `-`, `_` and `.` is Base64URL-encoded after two
colons, as in `Page::Y2Fmw6k` for `café`.

A `Zone` is a zone as this device sees it, a name and an owner. A string
literal is your own private zone, and `Zone.public` is the public database.
A zone someone shared with you keeps its name and takes the sharer as its
owner, so `zone.database` is `.private`, `.shared` or `.public` without
storing it.

```swift
let notes: Zone = "Notes"        // private, the same as Zone("Notes")
let board = Zone.public          // public
```

### References

`@Reference` holds a read-only reference to another record in the same zone, as the
target's own id, ready for CloudKit's `CKRecord.Reference`. The target is any
`Identifiable` type whose id is `Codable`.

```swift
struct Note: Codable, Identifiable {
    var id: UUID
    @Reference<Folder>(action: .deleteSelf) var folder: Folder.ID? = nil
}

let note = Note(id: UUID(), folder: folder.id)
note.folder           // the folder's id
note.$folder.zone     // the folder's zone, once the note is saved
```

The property is set when the model is created or decoded. It encodes a
`RecordReference` named as the target's record is, so `JSONEncoder` writes
`{"folder":{"action":"deleteSelf","recordName":"..."},"id":"..."}`, and
decoding reads the id back from that name. A `nil` reference is left out, and
a missing key decodes as `nil`.

CloudKit follows a reference only within its record's zone, so the target's
zone is always the holding record's. A reference built in code has no zone, and
the container places it in the record's zone when it saves the record. Saving
a reference that names another zone throws. The zone is encoded and is part of
the reference's equality. The projected value, `$folder`, is the wrapper
itself, which carries the target's type, id and zone together, as a view
needs to find the target.

The action follows `CKRecord.Reference`. With `.deleteSelf`, the record
holding the property deletes itself when the target is deleted. A decoded
reference keeps the action it was saved with. Swift does not pass the
attribute's arguments to `init(from:)`, so a reference decoded as `nil` has
the action `.none`.

### Reference lists

`@References` holds a read-only to-many relationship as the targets' own ids,
in order. The initializer picks how the list is stored, and the property reads
the same either way.

```swift
struct Note: Codable, Identifiable {
    var id: UUID
    @References<Attachment> var attachments: [Attachment.ID] = []
    @References<Tag>(inverse: \Tag.notes) var tags: [Tag.ID] = []
}

struct Tag: Codable, Identifiable {
    var id: UUID
    @References<Note>(inverse: \Note.tags) var notes: [Note.ID] = []
}
```

Without a key path the list is one reference list field, like `CKRecord`'s
own, so it travels with the record and two devices settle on one list. It
encodes each id as a `RecordReference` carrying the action, which a decoded
list takes from its first element. An empty field list is left out, and a
missing key decodes as an empty list.

A key path to the other side's list stores each reference as its own
`Relationship` record instead, so the list has no size limit and edits from two
devices merge. The two sides mirror each other: each names the other with
`inverse:`, either one can save a relationship, and both read it. The container
writes the relationships when it saves the record and fills the list back in
when it fetches it, so the record itself never holds them, and a predicate such
as `#Predicate { $0.tags.contains(tag.id) }` finds every note with a tag.
Deleting a record deletes its relationships too. A relationship list has no
action, because a `Relationship` record carries none.

A `Relationship` has two sides, sorted by property and then record, so both ends
build the same one. Side `i` is the record `references[i]`, holding the
relationship in its property `keyPaths[i]` at position `orders[i]` of that list.
Each side writes only its own order, so two devices reordering opposite sides
both keep their change, and removing a target renumbers nothing. Its id is its
record name, both properties and a stable hash of all four parts, as in
`Note.tags~Tag.notes:E621E1F8-C36C-495A-93FC-0C247A3E6E5F`. A symmetric list,
like `Person.friends`, names itself as its inverse.

Each property name comes from the coding key behind the key path, so it follows
`CodingKeys`. Finding it decodes a placeholder of the other type with a marker
id in each list, so the other side's id must encode as a JSON string or number,
as a `UUID`, `String` or `Int` does. Saving throws when two lists claim the same
inverse, because their key paths do not point at each other.

Use `@Reference` for one target and `@References` for many. Add a key path
when the list should merge across devices or outgrow a field.

### Parents

`@Reference(isParent: true)` points at the record that owns this one, and it is
saved as the record's `parent`. CloudKit shares a record together with
every record whose parent points at it, so sharing a folder shares its notes.

```swift
struct Note: Codable, Identifiable {
    var id: UUID
    @Reference<Folder>(isParent: true) var folder: Folder.ID? = nil
}
```

It takes no action, because CloudKit requires a parent reference to have the
action `.none`. Its reference encodes `"isParent": true`, so the flag
survives decoding and merging, and a record has at most one parent.

### Locations

`Location` holds every value a `CLLocation` saves to a CloudKit record:
coordinate, altitude, accuracies, course, speed and timestamp. It is a plain
`Codable` value, so optional locations and lists of locations work like any
other property, and on Apple platforms it converts to and from `CLLocation`.

```swift
struct Place: Codable {
    var home: Location?
    var route: [Location] = []
}

place.home?.latitude                    // 41.88
place.home?.clLocation                  // CLLocation
Location(clLocation)                    // back from CoreLocation
```

Unmeasured values follow CoreLocation: a negative accuracy, course or speed
means the value is invalid. CoreLocation exists only on Apple platforms, so
on Linux a `Location` has no `clLocation`.

### Timestamps

`@Timestamp` holds a read-only date that the server sets, such as when
CloudKit last modified the record.

```swift
struct Note: Codable, Hashable {
    var title: String
    @Timestamp var updatedOnServer: Date? = nil
}
```

The date is read when a model is decoded and never encoded, so it is never
sent back to the server. It takes no part in equality or hashing, so two
copies that differ only in when the server saved them are equal.

### Encrypted values

`@Encrypted` marks a property that CloudKit stores encrypted end to end. It
encodes exactly as its value does, so JSON is unchanged.

```swift
@Encrypted var body: String = ""
@Encrypted var pin: Int? = nil
```

CloudKit can encrypt strings, numbers, dates, data, locations and lists of
them, but not references or assets. Encrypted fields cannot be queried,
sorted or indexed.

### Assets

`@Asset` holds a file that CloudKit stores as a `CKAsset`. The property reads
and writes `Data`, and its projected value is the file's URL, for APIs that
work with files.

```swift
struct Note: Codable {
    @Asset var attachment: Data? = nil
}

note.attachment = bytes                 // writes a temporary file
note.$attachment = fileURL              // or points at a file you own
let pdf = PDFDocument(url: note.$attachment!)
```

Reading `attachment` maps the file into memory, so bytes load only as they
are used. The wrapper encodes the URL, not the bytes. A URL is local to one
device, and CloudKit hands back a new one each time a record is fetched.

### Transient values

`@Transient` holds a value only in memory, such as a cache or interface
state. It is never encoded, it is `nil` whenever a model is decoded, and it
takes no part in equality or hashing. Its value need not be `Codable`.

```swift
@Transient var thumbnail: Image? = nil
```

### Merging record values

The record values bring their own merge, so a `Mergeable` model merges them
by their rules with nothing to write:

- `Asset` keeps the side that changed the file. Files with the same bytes
  are the same asset, so only two different files conflict.
- `Encrypted` merges its value by the value's own merge.
- `Location` keeps the later measurement by `timestamp`.
- `@References` merges its ids element by element, keeping both sides'
  additions in place.

`Asset` and `Encrypted` are also `RawRepresentable`, so where a property
wrapper cannot go, as in a SwiftData model, a plain property holds the same
value: `var attachment: Asset` with `rawValue: URL?`, or
`var pin: Encrypted<Int>` with `rawValue: Int`.

## RecordContainer

`RecordContainer` is the database that holds records, a SQLite connection
and nothing more. It is opened for the record types it holds, as SwiftData's
`ModelContainer` is. The file lives in one place, `default.records` in
Application Support, or in an app group's shared container so an app and its
extensions share it. `storage: .inMemory` suits tests and previews.

```swift
let container = try RecordContainer(for: Note.self, Tag.self)        // Application Support/default.records
let preview = try RecordContainer(for: [Note.self], storage: .inMemory)  // in memory
let shared = try RecordContainer(for: Note.self, storage: .local(in: "group.com.example.notes"))
```

Opening a file throws a `DatabaseError` whose `description` says what SQLite
reported. On Linux, install SQLite's headers first
(`apt-get install libsqlite3-dev`).

## Requirements

- Swift 6.0 or later
- macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, or Linux with `libsqlite3-dev`
- The `main` branch of swift-versioning, which resolves to its newest commit

## Testing

```sh
swift test
```
