import ArgumentParser
import Darwin
import Foundation

enum CLIEntry {
    static func run(arguments: [String], appSupport: String, executable: String) -> Int32 {
        let files = FileService()
        let app = URL(fileURLWithPath: files.realPath(at: executable))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let info = (try? files.readData(at: app + "/Contents/Info.plist"))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let json = arguments.prefix { $0 != "--" }.contains("--json")
        var args = outputArgumentsRemoved(arguments)
        if args.first == "--version" { args[0] = "version" }
        do {
            if json, let help = try jsonHelp(args) { return printReply(.success(help), json: true) }
            let command = try PensieveCommand.parseAsRoot(args)
            let result = try execute(command, app: app, info: info,
                appSupport: supportDirectory(in: arguments, fallback: appSupport), files: files)
            return printReply(result.reply, json: json, human: result.human)
        } catch {
            if PensieveCommand.exitCode(for: error).rawValue == 0 {
                let message = PensieveCommand.fullMessage(for: error)
                return printReply(.success(.object(["help": .string(message)])), json: json, human: message + "\n")
            }
            return printReply(.failure("usage", PensieveCommand.fullMessage(for: error),
                hint: "Run pensieve commands or pensieve <command> --help.", exit: 64), json: json)
        }
    }

    private static func execute(_ command: ParsableCommand, app: String, info: [String: Any],
                                appSupport: String, files: FileServiceProtocol) throws -> (reply: CLIReply, human: String?) {
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let bundleID = info["CFBundleIdentifier"] as? String ?? "com.jaredatch.Pensieve"
        if let command = command as? ReadCommand {
            let client = CLIClient(appPath: app,
                socketPath: CLIProtocol.socketPath(appSupport: appSupport, bundleID: bundleID), fileService: files)
            return (client.send(command.request), nil)
        }
        if command is VersionCommand {
            return (.success(.object(["version": .string(version)])), "pensieve \(version)\n")
        }
        if command is CommandsCommand {
            return (.success(try CLICatalog.value(for: PensieveCommand.self)), PensieveCommand.helpMessage())
        }
        if let completion = command as? CompletionCommand {
            let script = PensieveCommand.completionScript(for: CompletionShell(rawValue: completion.shell) ?? .bash)
            return (.success(.object(["script": .string(script)])), script + "\n")
        }
        if command is StatusCommand || command is DeploymentListCommand || command is DeployedCommand || command is LogCommand {
            let name = command is StatusCommand ? "status" : (command is LogCommand ? "log" : "deployed")
            let result = CLIFileReads(appSupport: appSupport, fileService: files)
                .run(command: name, lines: (command as? LogCommand)?.lines ?? 20)
            return (result.reply, name == "deployed" ? nil : result.human)
        }
        return (.success(try CLICatalog.value(for: type(of: command))), type(of: command).helpMessage())
    }

    private static func outputArgumentsRemoved(_ args: [String]) -> [String] {
        var positional = false
        return args.filter { item in
            if item == "--" { positional = true }
            return positional || !["--json", "--no-input"].contains(item)
        }
    }

    private static func jsonHelp(_ args: [String]) throws -> CLIValue? {
        guard args.contains("--help") || args.contains("-h") else { return nil }
        let help = args.filter { !["--help", "-h"].contains($0) } + ["--experimental-dump-help"]
        do { _ = try PensieveCommand.parseAsRoot(help) } catch {
            guard PensieveCommand.exitCode(for: error).rawValue == 0 else { throw error }
            return try JSONDecoder().decode(CLIValue.self, from: Data(PensieveCommand.fullMessage(for: error).utf8))
        }
        return nil
    }

    private static func supportDirectory(in args: [String], fallback: String) -> String {
        let options = Array(args.prefix { $0 != "--" })
        for (index, item) in options.enumerated().reversed() {
            if item == "--app-support", options.indices.contains(index + 1) { return options[index + 1] }
            if item.hasPrefix("--app-support=") { return String(item.dropFirst("--app-support=".count)) }
        }
        return fallback
    }

    private static func printReply(_ reply: CLIReply, json: Bool, human: String? = nil) -> Int32 {
        if json {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let bytes = try encoder.encode(reply.envelope)
                FileHandle.standardOutput.write(bytes + Data([10]))
            } catch {
                FileHandle.standardError.write(Data("Unable to encode command result\n".utf8))
                return 1
            }
        } else if let error = reply.envelope.error {
            let text = DisplayTextSanitizer.singleLine(error.message) + "\n"
                + DisplayTextSanitizer.singleLine(error.hint) + "\n"
            FileHandle.standardError.write(Data(text.utf8))
        } else if let human {
            FileHandle.standardOutput.write(Data(human.utf8))
        } else if let data = reply.envelope.data {
            FileHandle.standardOutput.write(Data(render(data).utf8))
        }
        return reply.exitCode
    }

    private static func render(_ value: CLIValue) -> String {
        switch value {
        case let .string(text): DisplayTextSanitizer.logLine(text) + "\n"
        case let .array(items): items.map(render).joined()
        case let .object(fields): fields.keys.sorted().map { key in
            "\(key): \(fields[key].map(render)?.trimmingCharacters(in: .newlines) ?? "")"
        }.joined(separator: "\t") + "\n"
        case let .number(number): "\(number)\n"
        case let .decimal(number): "\(number)\n"
        case let .bool(flag): "\(flag)\n"
        case .null: "\n"
        }
    }
}
