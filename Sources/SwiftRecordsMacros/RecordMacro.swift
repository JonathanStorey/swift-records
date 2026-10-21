import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Record` adds `Record` conformance and generates `static var schema`, which maps every stored
/// property to its key path so predicates, sort descriptors, delete rules and inverses can be
/// resolved without an instance. It also gives each `@Timestamp` property its storage wrapper.
public struct RecordMacro: ExtensionMacro, MemberAttributeMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let variable = member.as(VariableDeclSyntax.self), timestampKind(variable.attributes) != nil,
              variable.bindings.count == 1, let binding = variable.bindings.first, isOptionalDate(binding) else {
            return []
        }
        return ["@SwiftRecords.TimestampStorage"]
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

        // `@Record(name:)` fixes the stored name, so renaming the struct keeps its data.
        var table = "\"\(structDecl.name.trimmedDescription)\""
        if case .argumentList(let arguments) = node.arguments,
           let name = arguments.first(where: { $0.label?.text == "name" })?.expression {
            guard let literal = name.as(StringLiteralExprSyntax.self), literal.segments.count == 1,
                  let segment = literal.segments.first?.as(StringSegmentSyntax.self),
                  isIdentifier(segment.content.text) else {
                throw MacroError.message(
                    "@Record(name:) takes a string literal of letters, digits and underscores that doesn't start with a digit"
                )
            }
            table = "\"\(segment.content.text)\""
        } else if context.lexicalContext.contains(where: { !$0.is(SourceFileSyntax.self) }) {
            // Records are stored under their simple name, so `Pantry.Item` and `Recipes.Item` would share a table.
            throw MacroError.message(
                "A nested @Record type needs @Record(name:), because it's stored under its simple name '\(structDecl.name.text)', which another type could also use"
            )
        }
        let access = structDecl.modifiers.contains { ["public", "open", "package"].contains($0.name.text) }
            ? "public " : ""

        var fields: [String] = []
        for member in structDecl.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self), isStored(variable) else { continue }
            let reference = referenceArguments(variable.attributes)
            let asset = assetArguments(variable.attributes)
            let modifiers = fieldModifiers(variable.attributes)
            // Another attribute may be a property wrapper, whose initial value isn't the stored value.
            let wrapped = variable.attributes.contains { element in
                guard let name = element.as(AttributeSyntax.self)?.attributeName.trimmedDescription else { return false }
                return !["Reference", "Renamed", "Indexed", "Asset", "SwiftRecords.Asset", "Timestamp", "SwiftRecords.Timestamp"].contains(name)
            }
            for binding in variable.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.trimmedDescription else {
                    continue
                }
                let keyPath = "\\\(typeName).\(name)"
                if reservedNames.contains(name) {
                    context.diagnose(Diagnostic(node: binding, message: MacroError.message(
                        "'\(name)' is a name SwiftRecords uses for its own bookkeeping. Choose another name"
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
                            "A @Timestamp property must be declared as 'Date?'"
                        )))
                        continue
                    }
                    fields.append(".timestamp(\"\(name)\", \(keyPath), \(kind))" + modifiers)
                    continue
                }
                if let inverse = reference?.from {
                    fields.append(".inverse(\"\(name)\", \(keyPath), of: \(inverse))" + modifiers)
                    continue
                }
                var field = reference?.deleteRule.map { ".field(\"\(name)\", \(keyPath), deleteRule: \($0))" }
                    ?? ".field(\"\(name)\", \(keyPath))"
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

    /// Column names the container uses for a record's position, version, change time and sync tag, and
    /// SQLite's own row ID.
    private static let reservedNames: Set<String> = ["_position", "_version", "_modified", "_tag", "rowid", "oid", "_rowid_"]

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

    /// The kind in a property's `@Timestamp` attribute, such as `.created`, or nil when it has none.
    private static func timestampKind(_ attributes: AttributeListSyntax) -> String? {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  ["Timestamp", "SwiftRecords.Timestamp"].contains(attribute.attributeName.trimmedDescription) else { continue }
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

    private static func isOptionalData(_ binding: PatternBindingSyntax) -> Bool {
        guard let type = binding.typeAnnotation?.type else { return false }
        let text = type.trimmedDescription.filter { !$0.isWhitespace }
        return ["Data?", "Foundation.Data?", "Optional<Data>", "Optional<Foundation.Data>"].contains(text)
    }

    private static func referenceArguments(_ attributes: AttributeListSyntax) -> (deleteRule: String?, from: String?)? {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  attribute.attributeName.trimmedDescription == "Reference" else { continue }
            var deleteRule: String?
            var from: String?
            if case .argumentList(let arguments) = attribute.arguments {
                for argument in arguments {
                    switch argument.label?.text {
                    case "deleteRule": deleteRule = argument.expression.trimmedDescription
                    case "from": from = argument.expression.trimmedDescription
                    default: break
                    }
                }
            }
            return (deleteRule, from)
        }
        return nil
    }
}

/// `@Renamed`, `@Indexed` and `@Timestamp` are markers read by `@Record`. They generate no code
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
