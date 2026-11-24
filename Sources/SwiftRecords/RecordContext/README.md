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
