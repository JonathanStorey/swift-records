import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Record` adds `Record` conformance and generates `static var schema`, which maps every stored
/// property to its key path so predicates, sort descriptors, references and inverses can be
/// resolved without an instance. It also gives each `@Timestamped` property, and each `Set` of IDs with `@Reference(to:)`, its
/// read-only storage wrapper.
public struct RecordMacro: ExtensionMacro, MemberMacro, MemberAttributeMacro {
    /// Declares `ID` on the struct itself, so another type can name `Recipe.ID` while the compiler is still
    /// working out `Recipe`'s conformances, such as when two types' relationships name each other.
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else { return [] }
        let declaresID = declaration.memberBlock.members.contains { member in
            member.decl.as(TypeAliasDeclSyntax.self)?.name.text == "ID"
        }
        guard !declaresID else { return [] }
        let access = declaration.modifiers.contains { ["public", "open", "package"].contains($0.name.text) } ? "public " : ""
        return ["\(raw: access)typealias ID = UUID"]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let variable = member.as(VariableDeclSyntax.self), variable.bindings.count == 1,
              let binding = variable.bindings.first else { return [] }
        if timestampKind(variable.attributes) != nil, isOptionalDate(binding) {
            return ["@SwiftRecords.TimestampStorage"]
        }
        if let reference = referenceArguments(variable.attributes) {
            if reference.isInverse(binding), binding.initializer == nil {
                return ["@SwiftRecords.InverseStorage"]
            }
            if reference.isRelationship(binding), variable.bindingSpecifier.tokenKind == .keyword(.var), binding.accessorBlock == nil {
                return ["@SwiftRecords.RelationshipStorage"]
            }
        }
        return []
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroError.message("@Record can only be applied to a struct")
        }

        if structDecl.genericParameterClause != nil {
            throw MacroError.message(
                "@Record can't be applied to a generic struct, because each specialization would need its own fixed table name. Use a concrete struct, or store the generic value in a Codable property of one"
            )
        }

        // The type as the extension names it, which qualifies a nested type such as `Pantry.Item`.
        let typeName = type.trimmedDescription

        // `@Record("Name")` fixes the stored name, so renaming the struct keeps its data.
        var table = "\"\(structDecl.name.trimmedDescription)\""
        if case .argumentList(let arguments) = node.arguments,
           let name = arguments.first(where: { $0.label == nil })?.expression {
            guard let literal = name.as(StringLiteralExprSyntax.self), literal.segments.count == 1,
                  let segment = literal.segments.first?.as(StringSegmentSyntax.self),
                  isIdentifier(segment.content.text) else {
                throw MacroError.message(
                    "@Record(_:) takes a string literal of letters, digits and underscores that doesn't start with a digit"
                )
            }
            table = "\"\(segment.content.text)\""
        } else if context.lexicalContext.contains(where: { !$0.is(SourceFileSyntax.self) }) {
            // Records are stored under their simple name, so `Pantry.Item` and `Recipes.Item` would share a table.
            throw MacroError.message(
                "A nested @Record type needs @Record(_:), because it's stored under its simple name '\(structDecl.name.text)', which another type could also use"
            )
        }
        let access = structDecl.modifiers.contains { ["public", "open", "package"].contains($0.name.text) }
            ? "public " : ""

        var fields: [String] = []
        for member in structDecl.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self), isStored(variable) else { continue }
            if variable.bindingSpecifier.tokenKind == .keyword(.let), variable.bindings.contains(where: { $0.initializer != nil }) {
                // Codable skips a `let` that has an initial value, so a fetched record would get a new one.
                let name = variable.bindings.first?.pattern.trimmedDescription ?? "property"
                context.diagnose(Diagnostic(
                    node: variable.bindingSpecifier,
                    message: MacroError.message(
                        "'\(name)' is a 'let' with an initial value, which decoding skips, so every fetch would give it a new value. Declare it with 'var'"
                    ),
                    fixIt: FixIt(message: MacroFixIt("Change 'let' to 'var'"), changes: [
                        .replace(
                            oldNode: Syntax(variable.bindingSpecifier),
                            newNode: Syntax(variable.bindingSpecifier.with(\.tokenKind, .keyword(.var)))
                        ),
                    ])
                ))
                continue
            }
            let reference = referenceArguments(variable.attributes)
            let asset = assetArguments(variable.attributes)
            let modifiers = fieldModifiers(variable.attributes)
            // Another attribute may be a property wrapper, whose initial value isn't the stored value.
            let wrapped = variable.attributes.contains { element in
                guard let name = element.as(AttributeSyntax.self)?.attributeName.trimmedDescription else { return false }
                return !["Reference", "Renamed", "Indexed", "Asset", "SwiftRecords.Asset", "Timestamped", "SwiftRecords.Timestamped"].contains(name)
            }
            for binding in variable.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.trimmedDescription else {
                    continue
                }
                let keyPath = "\\\(typeName).\(name)"
                if reservedNames.contains(name) {
                    context.diagnose(Diagnostic(node: binding, message: MacroError.message(
                        "'\(name)' is SQLite's name for a table's row ID. Choose another name"
                    )))
                    continue
                }
                if name == "id", !isUUID(binding) {
                    context.diagnose(Diagnostic(node: binding, message: MacroError.message(
                        "A record's 'id' must be a 'UUID'"
                    )))
                }
                if let asset {
                    guard isOptionalData(binding) else {
                        context.diagnose(Diagnostic(node: binding, message: MacroError.message(
                            "An @Asset property must be declared as 'Data?'"
                        )))
                        continue
                    }
                    let fileExtension = asset.fileExtension.map { ", fileExtension: \($0)" } ?? ""
                    fields.append(".asset(\"\(name)\", \(keyPath)\(fileExtension))" + modifiers)
                    continue
                }
                if let kind = timestampKind(variable.attributes) {
                    guard isOptionalDate(binding) else {
                        context.diagnose(Diagnostic(node: binding, message: MacroError.message(
                            "A @Timestamped property must be declared as 'Date?'"
                        )))
                        continue
                    }
                    fields.append(".timestamp(\"\(name)\", \(keyPath), \(kind))" + modifiers)
                    continue
                }
                if let reference {
                    if let field = referenceField(reference, name: name, keyPath: keyPath, binding: binding, in: context) {
                        fields.append(field + modifiers)
                    }
                    continue
                }
                var field = ".field(\"\(name)\", \(keyPath))"
                if name != "id", !wrapped, let value = defaultValue(binding) {
                    field += ".defaulting(\(value))"
                }
                fields.append(field + modifiers)
            }
        }

        let fieldList = fields.isEmpty ? "[]" : "[\n            " + fields.joined(separator: ",\n            ") + "\n        ]"
        let decl: DeclSyntax = """
            extension \(type.trimmed): Record {
                \(raw: access)static var schema: RecordSchema<\(raw: typeName)> {
                    RecordSchema(table: \(raw: table), fields: \(raw: fieldList))
                }
            }
            """
        return [decl.cast(ExtensionDeclSyntax.self)]
    }

    /// SQLite's names for a table's own row ID.
    private static let reservedNames: Set<String> = ["rowid", "oid", "_rowid_"]

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, !first.isNumber else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }

    private static func isStored(_ variable: VariableDeclSyntax) -> Bool {
        if variable.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }) {
            return false
        }
        for binding in variable.bindings {
            guard let accessors = binding.accessorBlock?.accessors else { continue }
            switch accessors {
            case .getter:
                return false
            case .accessors(let list):
                // willSet/didSet keep a property stored; get/set make it computed.
                if list.contains(where: { ["get", "set", "_read", "_modify"].contains($0.accessorSpecifier.text) }) {
                    return false
                }
            }
        }
        return true
    }

    private struct AssetAttribute {
        var fileExtension: String?
    }

    /// Reads a property's `@Asset` attribute, or returns nil when it has none.
    private static func assetArguments(_ attributes: AttributeListSyntax) -> AssetAttribute? {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  ["Asset", "SwiftRecords.Asset"].contains(attribute.attributeName.trimmedDescription) else { continue }
            var fileExtension: String?
            if case .argumentList(let arguments) = attribute.arguments {
                fileExtension = arguments.first { $0.label?.text == "fileExtension" }?.expression.trimmedDescription
            }
            return AssetAttribute(fileExtension: fileExtension)
        }
        return nil
    }

    /// False only when the declaration shows another type, so an `id` whose type is inferred from a call
    /// is left to the compiler.
    private static func isUUID(_ binding: PatternBindingSyntax) -> Bool {
        if let type = binding.typeAnnotation?.type {
            return ["UUID", "Foundation.UUID"].contains(type.trimmedDescription)
        }
        guard let value = binding.initializer?.value else { return true }
        return !(value.is(IntegerLiteralExprSyntax.self) || value.is(StringLiteralExprSyntax.self)
            || value.is(FloatLiteralExprSyntax.self) || value.is(BooleanLiteralExprSyntax.self))
    }

    /// The property's initial value, typed by its annotation, for decoding rows that lack it. Optionals
    /// already decode a missing value as nil, so they have none.
    private static func defaultValue(_ binding: PatternBindingSyntax) -> String? {
        guard let value = binding.initializer?.value.trimmedDescription else { return nil }
        guard let type = binding.typeAnnotation?.type else { return value }
        if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
            || type.trimmedDescription.hasPrefix("Optional<") {
            return nil
        }
        return "(\(value)) as \(type.trimmedDescription)"
    }

    /// The `.renamed(from:)` and `.indexed()` calls for a property's `@Renamed` and `@Indexed`.
    private static func fieldModifiers(_ attributes: AttributeListSyntax) -> String {
        var modifiers = ""
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            switch attribute.attributeName.trimmedDescription {
            case "Renamed":
                if case .argumentList(let arguments) = attribute.arguments {
                    let names = arguments.map(\.expression.trimmedDescription).joined(separator: ", ")
                    modifiers += ".renamed(from: \(names))"
                }
            case "Indexed":
                modifiers += ".indexed()"
            default:
                break
            }
        }
        return modifiers
    }

    /// The kind in a property's `@Timestamped` attribute, such as `.created`, or nil when it has none.
    private static func timestampKind(_ attributes: AttributeListSyntax) -> String? {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  ["Timestamped", "SwiftRecords.Timestamped"].contains(attribute.attributeName.trimmedDescription) else { continue }
            if case .argumentList(let arguments) = attribute.arguments, let kind = arguments.first?.expression.trimmedDescription {
                return kind.hasPrefix(".") ? kind : "." + (kind.split(separator: ".").last.map(String.init) ?? kind)
            }
            return ".modified"
        }
        return nil
    }

    private static func isOptionalDate(_ binding: PatternBindingSyntax) -> Bool {
        guard let type = binding.typeAnnotation?.type else { return false }
        let text = type.trimmedDescription.filter { !$0.isWhitespace }
        return ["Date?", "Foundation.Date?", "Optional<Date>", "Optional<Foundation.Date>"].contains(text)
    }

    fileprivate static func isSet(_ binding: PatternBindingSyntax) -> Bool {
        guard let type = binding.typeAnnotation?.type else { return false }
        let text = type.trimmedDescription.filter { !$0.isWhitespace }
        return text.hasPrefix("Set<") || text.hasPrefix("Swift.Set<")
    }

    private static func isOptionalData(_ binding: PatternBindingSyntax) -> Bool {
        guard let type = binding.typeAnnotation?.type else { return false }
        let text = type.trimmedDescription.filter { !$0.isWhitespace }
        return ["Data?", "Foundation.Data?", "Optional<Data>", "Optional<Foundation.Data>"].contains(text)
    }

    fileprivate static func isOptional(_ binding: PatternBindingSyntax) -> Bool {
        guard let type = binding.typeAnnotation?.type else { return false }
        return type.is(OptionalTypeSyntax.self) || type.trimmedDescription.hasPrefix("Optional<")
    }

    /// The arguments of a property's `@Reference` attribute.
    struct ReferenceAttribute {
        var from: ExprSyntax?
        var to: ExprSyntax?
        var action: String?
        var sort: ExprSyntax?
        var node: AttributeSyntax

        /// The type `to:` names, such as `Tag` for `Tag.self`, or nil for a key path.
        var toType: String? {
            guard let to, to.as(KeyPathExprSyntax.self) == nil else { return nil }
            return RecordMacro.typeName(to)
        }

        /// True for `@Reference(to: \Owner.links)` on a `Set` of IDs: the read-only side of a many-to-many.
        func isInverse(_ binding: PatternBindingSyntax) -> Bool {
            to?.as(KeyPathExprSyntax.self) != nil && RecordMacro.isSet(binding)
        }

        /// True for a `@Reference(to:)` that holds records: children as `[Child]` or `Child?`, or a
        /// many-to-many as `[Target]`.
        func isRelationship(_ binding: PatternBindingSyntax) -> Bool {
            guard from == nil, let to, !RecordMacro.holdsIDs(binding) else { return false }
            if to.as(KeyPathExprSyntax.self) != nil {
                return RecordMacro.isArray(binding) || RecordMacro.isOptional(binding)
            }
            return toType != nil && RecordMacro.isArray(binding)
        }
    }

    private static func referenceArguments(_ attributes: AttributeListSyntax) -> ReferenceAttribute? {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  ["Reference", "SwiftRecords.Reference"].contains(attribute.attributeName.trimmedDescription) else { continue }
            var reference = ReferenceAttribute(node: attribute)
            if case .argumentList(let arguments) = attribute.arguments {
                for argument in arguments {
                    switch argument.label?.text {
                    case "from": reference.from = argument.expression
                    case "to": reference.to = argument.expression
                    case "action": reference.action = argument.expression.trimmedDescription
                    case "sort": reference.sort = argument.expression
                    default: break
                    }
                }
            }
            return reference
        }
        return nil
    }

    /// The schema entry for a `@Reference` property, or nil after diagnosing a mistake.
    private static func referenceField(
        _ reference: ReferenceAttribute, name: String, keyPath: String, binding: PatternBindingSyntax,
        in context: some MacroExpansionContext
    ) -> String? {
        func diagnose(_ message: String, at node: some SyntaxProtocol) -> String? {
            context.diagnose(Diagnostic(node: node, message: MacroError.message(message)))
            return nil
        }
        if let from = reference.from {
            guard let parent = typeName(from) else {
                return diagnose("@Reference(from:) names the type this record comes from, such as 'Recipe.self'", at: from)
            }
            guard isOptional(binding) else {
                return diagnose("A @Reference(from:) property holds its parent's ID, or nil while it has none. Declare it as '\(parent).ID?'", at: binding)
            }
            let action = reference.action.map { ", action: \($0)" } ?? ""
            return ".reference(\"\(name)\", \(keyPath), from: \(parent).self\(action))"
        }
        guard let to = reference.to else {
            return diagnose("@Reference needs 'from:' or 'to:'", at: reference.node)
        }
        if let target = reference.toType {
            guard isArray(binding) else {
                return diagnose("A many-to-many relationship holds the records it links to. Declare it as '[\(target)]'", at: binding)
            }
            return ".links(\"\(name)\", \(keyPath), to: \(target).self\(sortArgument(reference.sort, root: target)))"
        }
        guard let path = to.as(KeyPathExprSyntax.self), let root = path.root?.trimmedDescription else {
            return diagnose("@Reference(to:) takes a key path with its type, such as '\\Step.recipe', or a type, such as 'Tag.self'", at: to)
        }
        if reference.isInverse(binding) {
            if reference.sort != nil {
                return diagnose("A set of IDs has no order, so it takes no 'sort:'", at: reference.sort!)
            }
            if let initializer = binding.initializer {
                return diagnose(
                    "This side of a many-to-many is read-only and filled by the container, so it takes no initial value. Remove '\(initializer.trimmedDescription)'",
                    at: initializer
                )
            }
            return ".inverse(\"\(name)\", \(keyPath), of: \(to.trimmedDescription))"
        }
        guard isArray(binding) || isOptional(binding), !holdsIDs(binding) else {
            return diagnose(
                "@Reference(to:) holds the records that point here: '[\(root)]' for many or '\(root)?' for one. The other side of a many-to-many is 'Set<\(root).ID>'",
                at: binding
            )
        }
        return ".children(\"\(name)\", \(keyPath), to: \(to.trimmedDescription)\(sortArgument(reference.sort, root: root)))"
    }

    /// The `sortBy:` argument for a `sort:`, with a key path's root filled in so it type-checks on its own.
    private static func sortArgument(_ sort: ExprSyntax?, root: String) -> String {
        guard let sort else { return "" }
        if let path = sort.as(KeyPathExprSyntax.self) {
            let keyPath = path.root == nil ? "\\\(root)" + path.components.trimmedDescription : path.trimmedDescription
            return ", sortBy: [SortDescriptor(\(keyPath))]"
        }
        return ", sortBy: \(sort.trimmedDescription)"
    }

    /// The type an expression such as `Recipe.self` names, or nil for any other expression.
    fileprivate static func typeName(_ expression: ExprSyntax) -> String? {
        guard let member = expression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "self",
              let base = member.base else { return nil }
        return base.trimmedDescription
    }

    /// True for a type such as `[Step.ID]` or `Step.ID?`, which names IDs where records belong.
    fileprivate static func holdsIDs(_ binding: PatternBindingSyntax) -> Bool {
        guard let type = binding.typeAnnotation?.type.trimmedDescription else { return false }
        let element = type.split(whereSeparator: { "[]?<>".contains($0) }).last.map(String.init) ?? type
        return element == "UUID" || element.hasSuffix(".ID")
    }

    fileprivate static func isArray(_ binding: PatternBindingSyntax) -> Bool {
        guard let type = binding.typeAnnotation?.type else { return false }
        return type.is(ArrayTypeSyntax.self) || type.trimmedDescription.hasPrefix("Array<")
    }
}

/// `@Renamed`, `@Indexed` and `@Timestamped` are markers read by `@Record`. They generate no code
/// themselves, and warn when they're used outside a `@Record` struct, where nothing reads them.
public struct MarkerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        warnOutsideRecord(node, in: context)
        return []
    }
}

/// `@Reference` is a marker read by `@Record`. It generates no code itself.
public struct ReferenceMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        warnOutsideRecord(node, in: context)
        return []
    }
}

/// Warns when a marker's property isn't a member of a `@Record` struct.
private func warnOutsideRecord(_ node: AttributeSyntax, in context: some MacroExpansionContext) {
    let isRecord = context.lexicalContext.first?.as(StructDeclSyntax.self)?.attributes.contains { element in
        guard let name = element.as(AttributeSyntax.self)?.attributeName.trimmedDescription else { return false }
        return name == "Record" || name == "SwiftRecords.Record"
    } ?? false
    guard !isRecord else { return }
    let name = node.attributeName.trimmedDescription
    context.diagnose(Diagnostic(node: node, message: MacroWarning(
        "@\(name) has no effect outside a @Record struct"
    )))
}

struct MacroFixIt: FixItMessage {
    let message: String
    init(_ message: String) { self.message = message }
    var fixItID: MessageID { MessageID(domain: "SwiftRecordsMacros", id: "fixit") }
}

enum MacroError: Error, CustomStringConvertible, DiagnosticMessage {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): text
        }
    }

    var message: String { description }
    var diagnosticID: MessageID { MessageID(domain: "SwiftRecordsMacros", id: "error") }
    var severity: DiagnosticSeverity { .error }
}

struct MacroWarning: DiagnosticMessage {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var diagnosticID: MessageID { MessageID(domain: "SwiftRecordsMacros", id: "warning") }
    var severity: DiagnosticSeverity { .warning }
}

@main
struct SwiftRecordsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [RecordMacro.self, ReferenceMacro.self, MarkerMacro.self]
}
