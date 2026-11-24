import Foundation

/// The place an app reads and edits records, as `ModelContext` is in SwiftData.
///
/// A context holds the edits not saved yet, and its ``container`` holds everything saved.
/// Views use the container's ``RecordContainer/mainContext``.
///
/// ```swift
/// let container = try RecordContainer(for: Note.self, Tag.self)
/// let context = container.mainContext
/// ```
///
/// Like `ModelContext`, a context is not `Sendable`. It stays on the actor that created it.
public final class RecordContext {
    /// The container this context reads from and saves into.
    public let container: RecordContainer
    /// The open drafts, each a ``Draft`` of its record's type, by the row they edit.
    var drafts: [RecordContainer.RowID: AnyObject] = [:]

    /// A new context on `container`, with no edits.
    init(_ container: RecordContainer) {
        self.container = container
    }
}

extension RecordContainer {
    /// The context views use, created on first use and the same one every time after.
    ///
    /// The container keeps it, and it keeps the container, so a container lives as long as
    /// the app once its main context is used, as a container normally does anyway.
    @MainActor public var mainContext: RecordContext {
        if let context = storedMainContext { return context }
        let context = RecordContext(self)
        storedMainContext = context
        return context
    }
}
