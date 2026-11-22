# RecordContainer

`RecordContainer` is a small SQLite database of records. Each record is a `Codable` Swift value, stored as JSON, together with everything needed to sync it with a server: the version the server last confirmed, this device's unsent changes, and the server's system fields. The container merges versions on its own, cleans up after itself, and never needs the user to settle anything.

This document explains what the container does under the hood and why. It covers the decisions behind merging, uploads, schema changes, assets and concurrency, and ends with a reference to every internal function.

## The shape of the database

A container is one SQLite connection with three tables.

| Table | What it holds |
| --- | --- |
| `record` | One row per record. |
| `record_type` | The schema each record type was last registered with. |
| `engine_state` | One opaque blob of sync state, saved and restored by whoever drives the container. |

A container is created for its record types, which it registers on opening. `RecordContainer(for:)` keeps the database in memory, so it starts empty and is gone with the container. `RecordContainer(for:url:)` keeps it in a file, created if needed. The database runs in WAL mode, so a read can run beside a write and each commit is cheap.

### The `record` row

Every row is read into a `Row` value, a plain struct with one property per column.

| Column | `Row` property | Meaning |
| --- | --- | --- |
| `id` | `id: UUID` | The record's name on the server and the table's primary key. |
| `zone`, `owner` | `zone: Zone` | The zone the record lives in, with its owner. |
| `type` | `type: String` | The record type, the Swift type's name, as in `"Note"`. |
| `metadata` | `metadata: Data?` | The server's archived system fields, or `nil` before the server first confirms the record. |
| `base` | `base: JSONRepresentation?` | What the server last confirmed, or `nil` for a record never uploaded. |
| `ours` | `ours: JSONRepresentation?` | This device's changes the server has not confirmed, or `nil` when there is nothing to upload. |
| `theirs` | `theirs: JSONRepresentation?` | A server version that could not merge and is waiting. |
| `sent` | `sent: JSONRepresentation?` | The version on its way to the server, kept until the server confirms it. |
| `is_deleted` | `isDeleted: Bool` | A local delete the server has not confirmed. |
| `error` | `error: String?` | Why something could not proceed. |

Three versions of one record can sit in a row at once. That is the whole trick. `base` is the common ancestor, `ours` is the local edit, and an incoming version is `theirs`. Every merge in the container is a three-way merge from those columns.

### Status is computed, never stored

A row's `status` is worked out from its columns each time it is read, so it can never drift out of step with them.

| `Row.Status` | When |
| --- | --- |
| `.conflict(String)` | `theirs` is waiting. The string is the reason. |
| `.rejected(String)` | There is an `error` and no `theirs`. |
| `.waitingToUpload` | There is an `ours`, or a delete waiting, and no error. |
| `.synced` | None of the above. |

The same rule appears in SQL in `pendingRows()`, which selects rows with no `theirs`, no `error`, and either an `ours` or a delete.

With every record type registered, `.conflict` never happens, because a registered type always settles its merge (see [Every merge settles](#every-merge-settles)). It remains for a record whose type this app does not know, which has no merge to run.

## The life of a record

### Saving locally

`save(our:id:zone:)` encodes the value to JSON and writes it into `ours` in one `INSERT … ON CONFLICT DO UPDATE` statement. A new id adds a row. An existing id replaces `ours`, clears `isDeleted` and `error`, and leaves `base`, `theirs`, `metadata` and the zone as they were.

The row's id comes from `recordID(for:type:)`. A `UUID` id is used as it is. Any other id, such as a slug, is hashed together with the record type into a stable UUID. Two devices that create the same id independently therefore write the same record, and the type is part of the hash because a record name must be unique in its zone across every type.

Saving never merges. A local save is always on top of whatever the device already had, so it simply replaces `ours`.

### Sending

`send(id:)` builds the record to upload. It starts from the row's archived system fields so the server can tell which version is being replaced. A row with no system fields, or with unreadable ones, starts from a new record in the row's zone.

Only the top-level fields whose JSON differs from `base` are encoded onto the record, because a server record uploads exactly the keys set on it. An unchanged asset is never uploaded again, and a field `ours` no longer has is set to `nil`, so the server clears it. A row with no `base` sends every field.

Before returning, `send(id:)` copies `ours` into `sent`. This matters because the server's confirmation holds only the fields that were sent, so the confirmation alone cannot say what the server now has. `sent` can.

A row that is synced, deleted, waiting to merge, or rejected sends nothing. A row whose `ours` cannot be encoded as its type sends nothing and records the reason in `error`.

### Confirming

`save(sent:)` handles the server's confirmation. It stores the new system fields and calls `Row.confirm(_:)` with the row's `sent` version, which does three things.

1. `sent` becomes `base`, because the server now holds exactly that.
2. If `ours` still equals `sent`, it becomes `nil`, since there is nothing left to upload.
3. `sent` and `error` are cleared.

Nothing merges on confirmation. If the user edited the record while it was in flight, that edit was made on top of what was sent, so it stays in `ours` and uploads next.

A row with no `sent`, which can happen if the confirmation arrives for an upload the container never recorded, cannot know what the server holds. It moves its content into `ours`, forgets `base`, and clears `error`, so the next send carries every field. Sending too much is safe. Guessing is not.

### Receiving

`save(their:id:zone:type:metadata:)` handles an incoming server version. It stores the new system fields and then calls `Row.receive(_:merging:)`.

- With no `ours`, there is nothing to merge. The incoming version becomes `base`, and `theirs` and `error` are cleared.
- With an `ours`, the incoming version merges into it by the registered type's merge. If the merged result equals the incoming version, `ours` becomes `nil`, because the server already has everything this device wanted. Otherwise the merged result becomes `ours` and uploads next. Either way the incoming version becomes the new `base`.
- If the merge throws, the incoming version waits in `theirs`, `error` says why, and `ours` and `base` are untouched. Nothing uploads until a later version settles it.

The type lookup happens before the row's lock is taken, since the lookup takes the same lock.

`save(their: CKRecord)` is the entry point for a server record. It decodes the record as its registered type into JSON, copies each asset file into the container, and hands the JSON to the function above. A record whose name is not a UUID was not written by this package, and a share record is not a record at all, so both are skipped.

### Failures

`save(failed:error:)` decides what a failed upload means.

| Error | What happens |
| --- | --- |
| The server has a newer version | That version is received and merged as above, and the next send replaces it. |
| The server has no such record | `ours` keeps the content (`ours ?? base`), and `metadata` and `base` are dropped, so the next send creates the record again with every field. |
| A missing zone, or a failure worth retrying | Nothing changes, so the record is sent again unchanged. |
| Anything else | The message goes into `error`. Nothing more uploads until the record is saved again. |

The retryable failures are a missing zone, a failed batch, network failures, an unavailable service, rate limiting and a busy zone.

### Deleting

`delete(id:)` behaves differently depending on whether the server has ever seen the record.

- A record with no `metadata` and no `base` has never been uploaded, so its row is removed at once.
- Any other record is marked `isDeleted`, and its `ours`, `theirs` and `error` are dropped. The delete then waits to upload.

Saving the record again before the delete uploads undoes the delete, because `save(our:)` clears `is_deleted`.

`save(deleted:)` handles the server reporting that a record is gone, whether because this device's delete was confirmed or because another device deleted it. The row is removed, unless this device has unsent changes and did not itself delete the record. Those changes win. The row forgets the server's version and keeps only `ours`, so the next send creates the record again. A user's edit is never silently lost to someone else's delete.

### Clearing

`clear()` removes every row, the stored sync state and every asset file, and sends nothing. It is for an account that signs out or changes.

`clear(in:resending:)` removes every row in one zone. With `resending: false`, unsent changes in that zone are dropped along with it, since the zone they belong to is gone. With `resending: true`, which is for a server that lost a zone's data but still expects its records, each row is kept and rebuilt as a brand new record. Its content (`ours ?? base`) becomes `ours` and everything else is forgotten, so it uploads again with every field. A row waiting to upload its delete is simply removed.

## Merging

Merging is where most of the container's decisions live. The goal is that a merge always produces a sensible result, never loses a user's edit to a field the other side did not touch, and never asks the user anything.

### Where merges run

A merge runs only when an incoming server version meets a row that has local changes. That happens in `save(their:)`, and through it when an upload fails because the server has a newer version. Local saves and confirmations never merge.

`merged(_:with:from:as:id:)` performs the merge in four steps.

1. Decode `ours`, `theirs` and `base` as the registered Swift type.
2. Merge the decoded values with the type's own merge, through `settled(_:with:from:)`.
3. Encode the result back to JSON.
4. Copy any asset file the merge produced into the row's folder.

Merging decoded Swift values, instead of raw JSON, lets each type bring its own rules. A counter can sum, a set can merge by membership, and an array of `Identifiable` elements can merge by id.

### Decode first, fill only when needed

Each version is first decoded exactly as it is. This is deliberate. If one side cleared an optional field, the stored JSON simply lacks that key, and decoding as it is reads `nil`. The cleared value stays cleared and the merge sees a real change.

Only if a version fails to decode does the container try again with each missing top-level key filled in from the other version (`decoded(as:filling:)`). This is what lets a version saved before a field existed still take part in a merge. Its missing field is borrowed from the other side, so the merge sees no change there and keeps the other side's value.

| Version | Filled from |
| --- | --- |
| `ours` | `theirs` |
| `theirs` | `ours` |
| `base` | `ours` filled from `theirs` |

### A version that cannot be read counts as missing

Even with filling, a version may not decode, for example if a field's type changed. Such a version is treated as absent instead of failing the merge.

| Readable | Result |
| --- | --- |
| `ours` and `theirs` | A normal merge. An unreadable `base` makes it a two-way merge. |
| `theirs` only | `theirs` wins. |
| `ours` only | `ours` is kept. |
| Neither | `theirs` is kept as it is. |

Fields the Swift type does not declare are dropped from the merged result, because the result is re-encoded from a Swift value.

### The type's own merge

Every registered type conforms to `Mergeable`. A plain `Codable` struct gets the default field-by-field merge with nothing to write. A type can also supply its own merge, by hand or with a strategy, as a counter does with `.rawValue(.sum())`.

The default merge encodes the three versions to JSON and merges them under the type's schema, with these rules.

- A value only one side changed takes that side's change.
- An object merges key by key, and so does a dictionary.
- A `Set` merges by membership. An element either side added is kept, and one either side removed is dropped.
- An array merges element by element, the way lines of text merge. If that fails, the whole array conflicts.
- An array or set of `Identifiable` elements merges by `id`, so an element both sides edited merges instead of looking like one removal and one addition.
- A property whose type is itself `Mergeable` merges by that type's own merge wherever both sides changed it, at any depth.
- A `Mergeable` property merges even when both sides made the same change. Two devices that each raise a counter from 3 to 4 end at 5, not 4.
- An enum with associated values encodes as an object with a single key, its case. When the two sides hold different cases, their payloads cannot be mixed, so the whole value conflicts instead of merging key by key into something that is neither case.
- A key one side removed while the other changed it conflicts.
- Without a `base`, only what both sides share merges: objects where both have the key, arrays of the same length, and sets with the same elements.

### Every merge settles

If the type's own merge throws a conflict, `settled(_:with:from:)` runs the merge again with `DefaultMergeStrategy(favoring:)`. This is the same smart merge with one difference. Every `Mergeable` property, `Identifiable` array and dictionary still merges by its own rules, and only a value that nothing settles keeps one side. The side comes from `favoring`.

| `favoring` | At each conflicting value |
| --- | --- |
| `.ours` (the default) | This device's value is kept. |
| `.theirs` | The server's value is kept. |

`favoring` is a `KeepMerge<JSONRepresentation>`, which has only those two cases, so the container cannot be told to leave a conflict standing. A standing conflict would stop the row from syncing until some later version happened to settle it, and the user would have no way to see or fix it.

`DefaultMergeStrategy` itself still accepts `favoring: nil`, and a type's default merge uses it. That is what makes the first attempt throw and name its paths, both for the container's two-step merge and for anyone calling `merging(with:)` directly.

The favored side wins only at the exact paths that conflict. If one device changed a note's title and the other changed both its title and its body, `.ours` keeps this device's title and still takes the other device's body.

## Schema changes

Every app update can change a record type. Devices running different versions of the app share the same records, so the container has to cope with records written by newer and older versions of the type. It sorts changes into two kinds.

- A **compatible** change can still read every record written before it. Adding an optional property and removing a property are compatible.
- A **breaking** change cannot. Adding a property that is not optional, or changing a property's type, are breaking.

### Compatible changes

**Adding an optional property.** An older record lacks the key and decodes with `nil`. If that older version takes part in a merge, decode-first finds it already readable, so nothing is filled and the property simply reads as unset on that side.

**Older devices keep fields they do not know.** An older app decodes a newer record as its own type, which drops the newer fields from its local copy. But when the older app edits the record, `send(id:)` uploads only the top-level fields that changed from `base`, and the server leaves every other field alone. The newer fields survive on the server untouched, and newer devices still see them.

**Removing a property.** The key is ignored when decoding. It stays on the server until something clears it.

### Breaking changes

**At registration.** When the container opens, `register(_:)` builds each type's `JSONSchema` and compares it with the schema stored in `record_type` from the last time the type was registered.

1. If the schemas are equal, nothing happens.
2. Otherwise the new schema is stored first.
3. If there was a stored schema and the new one is not a superset of it (`isSuperset(of:)`), the container asserts with a message that names the type and says how to fix it.

Storing first means the assert fires once, in the build that made the change, during development. The next launch runs on with the new schema as the baseline. A shipped build, with assertions off, never stops.

`isSuperset(of:)` asks whether a type with the new schema can decode every value written under the old one. In practice that means:

- Each property in the new schema either existed before with a compatible type, or is optional.
- A property's type may widen (an integer can be read as a floating-point number) but not narrow.
- A string enum may add cases but not remove them.
- An optional may hold anything the old non-optional held.
- Properties the old schema had and the new one dropped do not matter.

A property with a default value, such as `var color = "red"`, is still required by synthesized `Codable`, so adding one is a breaking change. Make it optional instead.

**At runtime.** A record this app cannot decode is skipped, never half-read.

- If a row for it already exists, only the row's `metadata` is updated. Its content stays as it was, and its next upload is sent against the server's newest version.
- If no row exists, nothing is saved.

Inside a merge, the same record counts as missing, as [described above](#a-version-that-cannot-be-read-counts-as-missing). Either way, one unreadable record never stops other records from saving or uploading.

### Guidance for changing a type

- Make every new property optional.
- Never change a property's type. Add a new optional property instead, and stop writing the old one.
- Keep every case of a string enum.
- Keep `CodingKeys` stable. A renamed key reads as one removed property and one added one.

## Assets

An `@Asset` property holds a file. A file cannot live inside JSON, so the JSON holds the file's URL and the file lives in the container's asset folder.

### Where files live

Each row has its own folder named by its id. The folder sits beside the database file in `<database>.assets/`, or, for an in-memory container, in a new temporary folder that is removed with the container.

Each version of a row that holds a file keeps its own copy, named `<key>-<UUID>`. `base`, `ours`, `theirs` and `sent` can then each point at a different file during a merge, and no version's file is ever overwritten.

### Copying in

`storingAssets(of:in:id:)` takes a record and its JSON, finds the record's files, copies each into the row's folder, and points its JSON field at the copy. It runs when a record is saved locally and when a merged result holds a file.

- A file already in the row's folder is kept as it is.
- A file with the same bytes as one the field already has in the folder points at the existing copy. Saving the same picture again is then no change, and nothing uploads.
- A file that cannot be copied keeps its original URL.
- On APFS a copy is a clone that shares the original's blocks, so copying is cheap.

An incoming server record already lists its files by field, so it goes straight to the overload `storingAssets(_:in:id:)`, which takes that list. The server's download location is temporary, so the container keeps its own copy.

The record's files are found by `assetFiles(of:)`, a private method on `JSONRepresentation`. It reads the file URL from each `@Asset` property and looks for the top-level JSON key whose string is that URL. Following the encoding instead of property names means a custom `CodingKeys` works. Assets are top-level only, because a nested value is stored as JSON, where a server record cannot hold a file.

### Portable paths

The app's sandbox can move, as iOS does when an app updates, so absolute file URLs would break. `portable(_:id:)` rewrites each URL inside the row's folder as `versioning-asset:<file name>` before a row is written, and `resolved(_:id:)` turns it back into an absolute URL when the row is read. Only the container's own copies are rewritten.

### Cleaning up

Two `sweepAssets` overloads do all the cleanup.

- `sweepAssets(of:)` is for a row that was written. It deletes every file in the row's folder that none of `base`, `ours`, `theirs` and `sent` still points at, and removes the folder once it is empty.
- `sweepAssets(id:)` is for a row that was removed. It deletes the row's whole folder.

Outside a transaction, either one cleans up at once. Inside a transaction, it adds the row's id to `assetsToSweep` and cleanup waits. `assetsToSweep` is private, so only `transaction(_:)` and the two overloads can touch it.

When `transaction(_:)` ends, by commit or by rollback, it reads each row in `assetsToSweep` back from the database and cleans up against what is really there. A row that cannot be read keeps its files. A rolled-back write therefore never deletes a file the restored row still needs, and files copied in for rows that never landed are removed.

## Encryption

An `@Encrypted` property is stored on the server's encrypted side. In the container's JSON it is an ordinary value, so encryption only matters when building an upload.

`send(id:)` encodes the full value into a scratch record and copies over only the changed keys. A changed key goes to the encrypted side if the new value's encoding put it there. A cleared key is on neither side of the new encoding, so the container also encodes `base` into a second scratch record and checks which side that key was on before. Both checks use the keys the encoder actually wrote, so a custom `CodingKeys` works here too.

A record with an `@Encrypted` value cannot be saved to `Zone.public`, because the public database has no encrypted side. `save(our:)` asserts on this.

## Concurrency

The connection is opened with `SQLITE_OPEN_FULLMUTEX`, so SQLite serializes every call on it. That alone is not enough, because many operations read a row, change it in Swift, and write it back. A recursive lock (`locked(_:)`) wraps each such read-and-write, along with registration, so no other thread can slip in between.

`transaction(_:)` takes the same lock and runs its body between `BEGIN IMMEDIATE` and `COMMIT`, rolling back if the body throws. Because the lock is recursive, the saves inside a transaction take it again without deadlocking. Batches of incoming records, confirmations and deletions each run as one transaction, so a batch lands whole or not at all.

`favoring`, `registrations` and `assetsToSweep` are only touched under the lock.

## Internal reference

Every function below is internal to the module unless marked otherwise.

### Setup and infrastructure

| Declaration | What it does |
| --- | --- |
| `init()` (public) | Opens an empty in-memory database. |
| `init(url: URL) throws(DatabaseError)` (public) | Opens or creates the database file at `url`. |
| `var url: URL?` (public) | The database file, or `nil` in memory. |
| `var assets: URL` | The folder holding every row's asset folder. |
| `var favoring: KeepMerge<JSONRepresentation>` | The side kept at values the type's own merge cannot settle. |
| `var assetsToSweep: Set<UUID>?` (private) | Rows whose asset cleanup waits for the current transaction, or `nil` outside one. |
| `func locked<T, Failure>(_ body: () throws(Failure) -> T) throws(Failure) -> T` | Runs `body` under the container's recursive lock. |
| `func transaction<T>(_ body: () throws(DatabaseError) -> T) throws(DatabaseError) -> T` | Runs `body` as one SQLite transaction, then sweeps assets. |
| `func sweepAssets(of row: Row)` | Removes a written row's unused files, now or after the current transaction. |
| `func sweepAssets(id: UUID)` | Removes a removed row's folder, now or after the current transaction. |
| `func execute(_ sql: String) throws(DatabaseError)` | Runs SQL that returns no rows. |
| `func run(_ sql: String, _ values: Any?..., each body:)` (private) | Prepares, binds and steps a statement, handing each result row to `body`. |

### Registering and identity

| Declaration | What it does |
| --- | --- |
| `func register<Record: Codable & Mergeable>(_ type: Record.Type)` | Registers a type for merging, stores its schema, and asserts on a breaking change. |
| `func registeredType(named type: String) throws -> RecordType` | The registered type for a record type name. `Relationship` is registered by default. |
| `static func recordType(of type: Any.Type) -> String` | The record type name, the Swift type's name. |
| `static func recordID(for id: any Encodable, type: String) throws -> UUID` | A `UUID` id as it is, or a stable hash of the type and any other id. |
| `func storedSchema(named name: String) -> JSONSchema?` | The schema a record type was last registered with. |
| `func store(_ schema: JSONSchema, named name: String)` | Saves a record type's schema. |

### Rows

| Declaration | What it does |
| --- | --- |
| `func row(id: UUID) throws(DatabaseError) -> Row?` | Reads a row, resolving its asset paths. |
| `func update(id: UUID, inserting new: Row?, _ change: (inout Row) -> Void) throws(DatabaseError)` | Reads, changes and writes a row under the lock, inserting `new` when there is none. |
| `func write(_ row: Row) throws(DatabaseError)` (private) | Writes every column with portable asset paths, then sweeps the row's assets. |
| `func remove(id: UUID) throws(DatabaseError)` (private) | Deletes a row and sweeps its folder. |
| `mutating func Row.receive(_ theirs:merging:)` | Takes an incoming version as `base`, merging it into `ours` first when there is one. |
| `mutating func Row.confirm(_ sent:)` | Takes a confirmed upload as `base`, keeping later local changes in `ours`. |
| `var Row.status: Row.Status` | The computed sync status. |
| `func pendingRows() throws(DatabaseError) -> [(id: UUID, zone: Zone, isDeleted: Bool)]` | Every row waiting to upload a save or a delete. |
| `func zones() throws(DatabaseError) -> Set<Zone>` | Every zone that holds a row. |

### Saving, deleting and clearing

| Declaration | What it does |
| --- | --- |
| `func save<Record, ID>(our record: Record, id: KeyPath<Record, ID>, zone: Zone) throws` | Saves a local version into `ours`. |
| `func save<Record: Identifiable>(our record: Record, zone: Zone) throws` | The same, identified by `id`. |
| `func save(their json: JSONRepresentation, id: UUID, zone: Zone, type: String, metadata: Data?) throws(DatabaseError)` | Saves an incoming version, merging when needed. |
| `func delete(id: UUID) throws(DatabaseError)` | Removes a never-uploaded row, or marks the row deleted. |
| `func delete<Record, ID>(our record: Record, id: KeyPath<Record, ID>) throws` | The same, by a record's id. |
| `func save(deleted id: UUID) throws(DatabaseError)` | Removes a row the server no longer has, unless unsent changes should recreate it. |
| `func clear() throws(DatabaseError)` | Removes every row, the sync state and every asset. |
| `func clear(in zone: Zone, resending: Bool = false) throws(DatabaseError)` | Removes a zone's rows, or rebuilds them as new records. |
| `var engineStateData: Data?` | The opaque sync state blob. Reading and writing never throw. |

### Merging

| Declaration | What it does |
| --- | --- |
| `func merged<Record>(_ ours:with theirs:from base:as type:id:) throws -> JSONRepresentation` | Decodes, merges, re-encodes and stores assets. |
| `func settled<Record>(_ ours:with theirs:from base:) throws(MergeConflict) -> Record` (private) | The type's own merge, then the favoring strategy on conflict. |
| `func JSONRepresentation.decoded<T>(as:filling:) -> T?` (private) | Decodes as it is, or with missing keys filled from the other version. |
| `func JSONRepresentation.filling(from:) -> JSONRepresentation` (private) | Adds each top-level key this object lacks from another. |

### Server records

| Declaration | What it does |
| --- | --- |
| `func save(their record: CKRecord) throws(DatabaseError)` | Decodes and saves an incoming record, or only its system fields when it cannot be read. |
| `func save(their records: some Sequence<CKRecord>) throws(DatabaseError)` | The same for a batch, in one transaction. |
| `func send(id: UUID) throws(DatabaseError) -> CKRecord?` | Builds the upload with only changed fields, and keeps `sent`. |
| `func save(sent record: CKRecord) throws(DatabaseError)` | Confirms an upload from `sent`. |
| `func save(sent records: some Sequence<CKRecord>) throws(DatabaseError)` | The same for a batch, in one transaction. |
| `func save(failed record: CKRecord, error: CKError) throws(DatabaseError)` | Merges, retries, recreates or records the error. |
| `func send(deleted id: UUID) throws(DatabaseError) -> CKRecord.ID?` | The id to delete, when a delete is waiting. |
| `func save(deleted id: CKRecord.ID) throws(DatabaseError)` | The server no longer has a record. |
| `func save(deleted ids: some Sequence<CKRecord.ID>) throws(DatabaseError)` | The same for a batch, in one transaction. |
| `func save(failed id: CKRecord.ID, error: CKError) throws(DatabaseError)` | Handles a failed delete. |
| `func save(deleted zoneID: CKRecordZone.ID, reason: CKDatabase.DatabaseChange.Deletion.Reason) throws(DatabaseError)` | Clears a deleted zone, resending its records after an encrypted data reset. |
| `func pendingChanges() throws(DatabaseError) -> (saves: [CKRecord.ID], deletes: [CKRecord.ID])` | Every waiting upload, as record ids. |

### Assets

| Declaration | What it does |
| --- | --- |
| `func assetFolder(id: UUID) -> URL` | A row's asset folder. |
| `func storingAssets(of record: Any, in json: JSONRepresentation, id: UUID) -> JSONRepresentation` | Finds a record's asset files and copies them into the row's folder. |
| `func storingAssets(_ files: [String: URL], in json: JSONRepresentation, id: UUID) -> JSONRepresentation` | Copies files listed by field into the row's folder, reusing identical ones. |
| `func JSONRepresentation.assetFiles(of record: Any) -> [String: URL]` (private) | Each asset file by the JSON key that holds it. |
| `func portable(_ json: JSONRepresentation, id: UUID) -> JSONRepresentation` | Rewrites the row's file URLs as relative names. |
| `func resolved(_ json: JSONRepresentation, id: UUID) -> JSONRepresentation` | Turns relative names back into URLs. |
| `var Mirror.properties: [(name: String, value: Any)]` | Each stored property, with a property wrapper under its own name. |
