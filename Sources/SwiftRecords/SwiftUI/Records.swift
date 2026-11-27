#if canImport(SwiftUI)
import SwiftUI

/// The records a view lists, fetched through the environment's
/// `recordContext`, as `@Query` lists models in SwiftData.
///
/// A descriptor picks records by predicate and order, and a reference list's projected value
/// lists its targets in order, whether it is a field list or a relationship list:
///
/// ```swift
/// @Records var notes: [Note]
/// @Records(RecordDescriptor(predicate: #Predicate { !$0.isArchived })) var active: [Note]
/// @Records(note.$tags) var tags: [Tag]
/// ```
///
/// The list includes the context's unsaved edits, and leaves out what it deleted. Reading it
/// observes the context, so the view redraws on every insert, edit, delete and save, from this
/// context or from anywhere that saves to its container. A fetch that throws reads as empty.
///
/// A reference list is the list as it was when the view was made. A view that passes
/// `note.$tags` redraws when `note` changes, which makes a new list from the new value.
@MainActor @propertyWrapper
public struct Records<Record: Codable>: DynamicProperty {
    @Environment(\.recordContext) private var context
    /// Reads the records from a context.
    private let fetch: (RecordContext) throws -> [Record]

    /// The records, fetched now.
    public var wrappedValue: [Record] {
        (try? fetch(context)) ?? []
    }

    /// The records `descriptor` describes, every record of the type by default.
    public init(_ descriptor: RecordDescriptor<Record> = RecordDescriptor()) {
        fetch = { try $0.fetch(descriptor) }
    }

    /// The records `references` lists, in its order, without the ones deleted or not yet
    /// arrived.
    public init(_ references: References<Record>) where Record: Identifiable, Record.ID: Codable & Sendable {
        fetch = { $0.fetch(references) }
    }
}
#endif
