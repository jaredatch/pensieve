import ArgumentParser
import Darwin
import Foundation

enum CLIEntry {
    private static let outputLock = NSLock()
    private static var printedExitCode: Int32?

    static func interrupted(arguments: [String]) -> Int32 {
        printReply(.failure("interrupted", "Interrupted. Pensieve finishes any command it already accepted.",
            hint: "Check Pensieve before trying again.", exit: 130),
            json: arguments.prefix { $0 != "--" }.contains("--json"))
    }

    static func run(arguments: [String], appSupport: String, executable: String) -> Int32 {
        let files = FileService()
        let app = URL(fileURLWithPath: files.realPath(at: executable))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let info = (try? files.readData(at: app + "/Contents/Info.plist"))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        // This only selects the format for parser failures; successful commands use decoded options.
        var json = arguments.prefix { $0 != "--" }.contains("--json")
        do {
            let command: ParsableCommand
            let options: OutputOptions
            if arguments.prefix(while: { $0 != "--" }).contains("--version") {
                let version = try VersionOptions.parse(arguments)
                command = VersionCommand()
                options = version.output
            } else {
                command = try PensieveCommand.parseAsRoot(arguments)
                guard let output = command as? OutputCommand else {
                    var help = command
                    try help.run()
                    return 0
                }
                options = output.output
            }
            json = options.json
            let result = try execute(command, app: app, info: info,
                appSupport: options.appSupport ?? appSupport, defaultAppSupport: appSupport, files: files)
            return printReply(result.reply, json: json, human: result.human)
        } catch {
            if PensieveCommand.exitCode(for: error).rawValue == 0 {
                if json, let help = try? jsonHelp(arguments) { return printReply(.success(help), json: true) }
                let message = PensieveCommand.fullMessage(for: error)
                return printReply(.success(.object(["help": .string(message)])), json: json, human: message + "\n")
            }
            return printReply(.failure("usage", PensieveCommand.fullMessage(for: error),
                hint: "Run pensieve commands or pensieve <command> --help.", exit: 64), json: json)
        }
    }

    private static func execute(_ command: ParsableCommand, app: String, info: [String: Any],
                                appSupport: String, defaultAppSupport: String,
                                files: FileServiceProtocol) throws -> (reply: CLIReply, human: String?) {
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let bundleID = info["CFBundleIdentifier"] as? String ?? "com.jaredatch.Pensieve"
        let request: CLIRequest?
        if let command = command as? DeployCommand {
            request = try command.targets.request(command: "deploy", output: command.output)
        } else if let command = command as? UndeployCommand {
            request = try command.targets.request(command: "undeploy", output: command.output)
        } else { request = (command as? ReadCommand)?.request }
        if let request {
            let client = CLIClient(appPath: app,
                socketPath: CLIProtocol.socketPath(appSupport: appSupport, bundleID: bundleID), fileService: files,
                launcher: CLIAppLauncher(fileService: files,
                    usesAlternateAppSupport: files.realPath(at: appSupport) != files.realPath(at: defaultAppSupport)),
                bundleID: bundleID)
            return (client.send(request), nil)
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
            let reader = CLIFileReads(appSupport: appSupport, fileService: files)
            let result = reader.run(command: name, lines: (command as? LogCommand)?.lines ?? 20)
            let human = name == "status" ? reader.statusSummary(for: result).map {
                $0 + (result.envelope.data.map { render($0) } ?? "")
            } : nil
            return (result, human)
        }
        return (.success(try CLICatalog.value(for: type(of: command))), type(of: command).helpMessage())
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

    private static func printReply(_ reply: CLIReply, json: Bool, human: String? = nil) -> Int32 {
        outputLock.lock()
        defer { outputLock.unlock() }
        if let printedExitCode { return printedExitCode }
        printedExitCode = reply.exitCode
        if json {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let bytes = try encoder.encode(reply.envelope)
                FileHandle.standardOutput.write(bytes + Data([10]))
            } catch {
                FileHandle.standardError.write(Data("Unable to encode command result\n".utf8))
                printedExitCode = 1
                return 1
            }
        } else {
            if let human {
                FileHandle.standardOutput.write(Data(human.utf8))
            } else if let data = reply.envelope.data {
                FileHandle.standardOutput.write(Data(render(data).utf8))
            }
            if let error = reply.envelope.error {
                let text = DisplayTextSanitizer.singleLine(error.message) + "\n"
                    + DisplayTextSanitizer.singleLine(error.hint) + "\n"
                FileHandle.standardError.write(Data(text.utf8))
            }
        }
        return reply.exitCode
    }

    private static func render(_ value: CLIValue, indent: String = "") -> String {
        switch value {
        case let .string(text):
            return normalizedLines(text).components(separatedBy: "\n").map {
                indent + DisplayTextSanitizer.logLine($0).replacingOccurrences(of: "\t", with: "    ")
            }.joined(separator: "\n") + "\n"
        case let .array(items):
            if items.isEmpty { return indent + "[]\n" }
            return items.map { indent + "-\n" + render($0, indent: indent + "  ") }.joined()
        case let .object(fields):
            return renderFields(fields, indent: indent)
        case let .number(number): return "\(indent)\(number)\n"
        case let .decimal(number): return "\(indent)\(number)\n"
        case let .bool(flag): return "\(indent)\(flag)\n"
        case .null: return indent + "null\n"
        }
    }

    private static func renderFields(_ fields: [String: CLIValue], indent: String) -> String {
        if fields.isEmpty { return indent + "{}\n" }
        return fields.keys.sorted().map { key in
            let label = indent + DisplayTextSanitizer.singleLine(key).replacingOccurrences(of: "\t", with: "") + ":"
            let value = fields[key] ?? .null
            switch value {
            case .array, .object:
                return label + "\n" + render(value, indent: indent + "  ")
            case let .string(text) where normalizedLines(text).contains("\n"):
                return label + "\n" + render(value, indent: indent + "  ")
            default:
                return label + " " + render(value)
            }
        }.joined()
    }

    private static func normalizedLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

private struct VersionOptions: ParsableArguments {
    @OptionGroup var output: OutputOptions
    @Flag var version = false
}

private protocol OutputCommand: ParsableCommand {
    var output: OutputOptions { get }
}

extension PensieveCommand: OutputCommand {}
extension SkillCommand: OutputCommand {}
extension SkillListCommand: OutputCommand {}
extension SkillsCommand: OutputCommand {}
extension SkillShowCommand: OutputCommand {}
extension AgentCommand: OutputCommand {}
extension AgentListCommand: OutputCommand {}
extension MachineCommand: OutputCommand {}
extension MachineListCommand: OutputCommand {}
extension ProjectCommand: OutputCommand {}
extension ProjectListCommand: OutputCommand {}
extension DeploymentCommand: OutputCommand {}
extension DeploymentListCommand: OutputCommand {}
extension DeployedCommand: OutputCommand {}
extension StatusCommand: OutputCommand {}
extension LogCommand: OutputCommand {}
extension CommandsCommand: OutputCommand {}
extension CompletionCommand: OutputCommand {}
extension VersionCommand: OutputCommand {}

extension DeployCommand: OutputCommand {}
extension UndeployCommand: OutputCommand {}
extension SyncCommand: OutputCommand {}
