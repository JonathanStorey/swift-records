import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Record` adds `Record` conformance and generates `static var schema`, which maps every stored
/// property to its key path so predicates, sort descriptors, delete rules and inverses can be
/// resolved without an instance.
public struct RecordMacro: ExtensionMacro {
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

        let typeName = structDecl.name.trimmedDescription
        let access = structDecl.modifiers.contains { ["public", "open", "package"].contains($0.name.text) }
            ? "public " : ""

        var fields: [String] = []
        for member in structDecl.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self), isStored(variable) else { continue }
            let reference = referenceArguments(variable.attributes)
            for binding in variable.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.trimmedDescription else {
                    continue
                }
                let keyPath = "\\\(typeName).\(name)"
                if let inverse = reference?.from {
                    fields.append(".inverse(\"\(name)\", \(keyPath), of: \(inverse))")
                } else if let rule = reference?.deleteRule {
                    fields.append(".field(\"\(name)\", \(keyPath), deleteRule: \(rule))")
                } else {
                    fields.append(".field(\"\(name)\", \(keyPath))")
                }
            }
        }

        let fieldList = fields.isEmpty ? "[]" : "[\n            " + fields.joined(separator: ",\n            ") + "\n        ]"
        let decl: DeclSyntax = """
            extension \(type.trimmed): Record {
                \(raw: access)static var schema: RecordSchema<\(raw: typeName)> {
                    RecordSchema(table: "\(raw: typeName)", fields: \(raw: fieldList))
                }
            }
            """
        return [decl.cast(ExtensionDeclSyntax.self)]
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

/// `@Reference` is a marker read by `@Record`. It generates no code itself.
public struct ReferenceMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

enum MacroError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}

@main
struct SwiftRecordsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [RecordMacro.self, ReferenceMacro.self]
}
