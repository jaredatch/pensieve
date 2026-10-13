import ArgumentParser
import Foundation

enum CLICatalog {
    static func value(for command: ParsableCommand.Type) throws -> CLIValue {
        let raw = try JSONDecoder().decode(CLIValue.self, from: Data(command._dumpHelp().utf8))
        guard case var .object(fields) = raw, let tree = fields["command"] else { return raw }
        fields["command"] = addingAliases(to: tree, type: command)
        return .object(fields)
    }

    private static func addingAliases(to value: CLIValue, type: ParsableCommand.Type) -> CLIValue {
        guard case var .object(fields) = value else { return value }
        var aliases = type.configuration.aliases
        if type == VersionCommand.self { aliases.append("--version") }
        fields["aliases"] = .array(aliases.map(CLIValue.string))
        if case let .array(children) = fields["subcommands"] {
            fields["subcommands"] = .array(children.map { child in
                guard case let .object(childFields) = child,
                      let childType = type.configuration.subcommands.first(where: {
                          childFields["commandName"] == .string($0.configuration.commandName ?? "")
                      }) else { return child }
                return addingAliases(to: child, type: childType)
            })
        }
        if type == PensieveCommand.self {
            fields["parserFlags"] = .array([.string("--experimental-dump-help"),
                                             .string("--generate-completion-script[=<shell>]")])
        }
        return .object(fields)
    }
}
