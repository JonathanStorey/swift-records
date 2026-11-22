extension Mirror {
    /// Each stored property's name and value, a property wrapper's under the property's own
    /// name rather than its storage's, which adds an underscore.
    var properties: [(name: String, value: Any)] {
        children.compactMap { child in
            child.label.map { (name: $0.hasPrefix("_") ? String($0.dropFirst()) : $0, value: child.value) }
        }
    }
}
