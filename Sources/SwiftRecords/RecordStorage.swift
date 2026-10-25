#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// Keeps one record as a setting, as `@AppStorage` keeps a value, in a zone of its own that syncs like any
/// other.
///
/// ```swift
/// @RecordStorage var preferences = Preferences()             // the key is the type's table name
/// @RecordStorage("favorite") var favorite = Recipe(title: "")
///
/// Toggle("Metric", isOn: $preferences.metric)
/// ```
///
/// Each key has its own zone, `Zone.settings("favorite")`, so settings never mix with each other or with
/// app data, and switching `context.zone` doesn't move them. Until the first edit stores the record, it reads
/// as the default value. Edits go through the container's `mainContext` and show in every view at once,
/// including views on other devices once they sync.
///
/// If two devices each store the setting before they sync, the zone briefly holds two records. Every device
/// shows the one with the lower ID, the older with `UUID.ordered()`, and the next edit deletes the other.
@MainActor
@propertyWrapper
@dynamicMemberLookup
public struct RecordStorage<R: Record>: DynamicProperty {
    @Environment(\.recordContainer) private var container
    @Records private var records: [R]

    private let defaultValue: R
    /// The setting's zone.
    public let zone: Zone

    /// Stores the setting under `key`, the type's table name by default. Changes animate with the default
    /// animation unless you pass another, or `nil` for none.
    public init(wrappedValue: R, _ key: String? = nil, animation: Animation? = .default) {
        defaultValue = wrappedValue
        zone = .settings(key ?? Zone.settingsKey(for: R.table))
        _records = Records(zone, RecordDescriptor(), animation: animation)
    }

    /// The setting, or the default value until it's stored. Setting it stores it.
    public var wrappedValue: R {
        get { records.setting ?? defaultValue }
        nonmutating set { Self.store(newValue, current: records, context: context, zone: zone) }
    }

    /// The wrapper itself, whose members bind to the record's properties: `$preferences.metric`.
    public var projectedValue: RecordStorage<R> { self }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<R, Value>) -> Binding<Value> {
        binding[dynamicMember: keyPath]
    }

    /// The whole setting as a binding, for a child view that takes one.
    public var binding: Binding<R> {
        let results = $records
        let context = context
        let defaultValue = defaultValue
        let zone = zone
        return Binding(
            get: {
                MainActor.assumeIsolated { Array(results.wrappedValue).setting ?? defaultValue }
            },
            set: { newValue in
                MainActor.assumeIsolated {
                    Self.store(newValue, current: Array(results.wrappedValue), context: context, zone: zone)
                }
            }
        )
    }

    /// Whether the setting has been stored, here or on another device.
    public var isStored: Bool { !records.isEmpty }

    /// Deletes the stored setting everywhere, so it reads as the default value again.
    public func restoreDefault() {
        guard let context else { return }
        for record in records {
            context.delete(record, in: zone)
        }
    }

    private var context: RecordContext? { mainContext(of: container) }

    private static func store(_ value: R, current: [R], context: RecordContext?, zone: Zone) {
        context?.storeSetting(value, replacing: current, in: zone)
    }
}
#endif
