# Crate

A record collection app that exercises SwiftRecords end to end, with real CloudKit sync between a Mac and
an iPhone. It keeps artists, albums with cover art and track lists, genres, playlists, and the friends
you lend records to.

| Part | What it is | Builds on |
| --- | --- | --- |
| `Sources/CrateModels` | The records, a sample crate and the everyday actions | Linux, macOS, iOS |
| `Sources/CrateUI` | Every screen, as `CrateRootView` | macOS, iOS |
| `Tests/CrateModelsTests` | Relationships, wrappers and merges, without sync | Linux, macOS |
| `App/Crate.xcodeproj` | One multiplatform app target that shows `CrateRootView` | macOS, iOS |

## What it covers

| Feature | Where |
| --- | --- |
| One to many, `.nullify` | `Artist.albums` and `Album.artist` |
| One to many in order, `.deleteSelf` | `Album.tracks`, sorted by `position`, reordered by dragging |
| Many to many, with the other side as IDs | `Album.genres` and `Genre.albumIDs`, read with `@Records(ids:)` |
| Many to many in the owner's order | `Playlist.tracks` and `Track.playlistIDs` |
| A link with its own properties | `Loan`, between `Album` and `Friend` |
| `@Asset` | `Album.cover`, drawn or picked from Photos |
| `@Merged(.sum)`, `@Merged(.maximum)` | plays and ratings |
| Nested values and sets that merge by part | `Album.credits`, `Album.tags` |
| `Mergeable` | `Playlist`, which merges itself |
| `@Timestamped(.created/.modified/.synced)` | album and artist pages |
| `@Indexed`, `@Encrypted`, `@Renamed` | `year` and `country`, `price`, `linerNotes` |
| `@Records`: sort, search, paging | Albums, and Artists four to a page |
| `@Recordable` live, `.draft`, `startNew()` | album page, Edit sheet, New album sheet |
| Conflicts in an open editor | banners and orange fields, with Use theirs and Keep mine |
| `@RecordStorage` | the settings on the Sync tab |
| `status`, `unsynced`, `isSynced`, `refresh()`, autosave | the Sync tab and the cloud badges |

## Run it on your Mac and iPhone

1. Open `Examples/Crate/App/Crate.xcodeproj` in Xcode 16 or later.
2. Select the Crate target, then Signing & Capabilities. Choose your team, and change the bundle
   identifier from `com.example.Crate` to one of yours, such as `com.yourname.Crate`.
3. In the iCloud section, check the container `iCloud.<your bundle identifier>`, or press + to create it.
   The entitlements already ask for CloudKit, push notifications and, on iOS, the remote notification
   background mode.
4. Run on the Mac (My Mac) and on the iPhone, signed in to the same Apple Account on both.
5. On one device only, tap Add the sample crate. The other device fills in within a few seconds. The first
   sync after creating a container can take a minute while CloudKit makes the schema.

## Things to try

- **Plays add up.** Turn on airplane mode on the iPhone, press Played it three times there and twice on the
  Mac, then reconnect. Both show five more plays.
- **The higher rating wins.** Offline, rate an album 2 on one device and 4 on the other.
- **Fields merge apart.** Offline, change the label on one device and the producer on the other. Both stay.
- **A conflict in an open editor.** Open an album on the iPhone, change its title without leaving the
  field. On the Mac, change the same title. The iPhone shows the banner and an orange field.
- **The Conflict Lab** on the Sync tab does the same on one device: open an album, edit a field, go back,
  and press a button to save a change from "another device."
- **Drafts.** Open Edit, change things, and watch the album list stay as it was until Save.
- **Deletes.** Delete an album on the Mac while its Edit sheet is open on the iPhone. Save brings it back.
- **Settings sync.** Change the sort order on one device and watch the other follow.

## Tests

`swift test` in this folder runs the model tests on any platform, Linux included.
