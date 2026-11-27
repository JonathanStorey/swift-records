#if canImport(SwiftUI)
import SwiftUI

extension EnvironmentValues {
    /// The context views read and edit records through, as `modelContext` is in SwiftData.
    ///
    /// `recordContainer(_:)` sets it to a container's
    /// ``RecordContainer/mainContext``. Until then it is a context on an empty container held
    /// in memory, so lists are empty and the first insert asserts that its type is not
    /// registered.
    ///
    /// ```swift
    /// @Environment(\.recordContext) private var context
    /// ```
    public var recordContext: RecordContext {
        get { self[RecordContextKey.self] }
        set { self[RecordContextKey.self] = newValue }
    }
}

/// A `RecordContext` is not `Sendable`, so the default is made when read, not stored.
private struct RecordContextKey: EnvironmentKey {
    static var defaultValue: RecordContext { RecordContext(.placeholder) }
}

extension View {
    /// Sets `recordContext` to `container`'s
    /// ``RecordContainer/mainContext`` for this view and every view inside it, as
    /// `modelContainer(_:)` does in SwiftData.
    ///
    /// ```swift
    /// NoteList()
    ///     .recordContainer(container)
    /// ```
    public func recordContainer(_ container: RecordContainer) -> some View {
        environment(\.recordContext, container.mainContext)
    }
}

extension Scene {
    /// Sets `recordContext` to `container`'s
    /// ``RecordContainer/mainContext`` for every window of this scene.
    ///
    /// ```swift
    /// WindowGroup {
    ///     NoteList()
    /// }
    /// .recordContainer(container)
    /// ```
    public func recordContainer(_ container: RecordContainer) -> some Scene {
        environment(\.recordContext, container.mainContext)
    }
}

extension RecordContainer {
    /// The empty container behind the environment's default context.
    static let placeholder = RecordContainer()
}
#endif
