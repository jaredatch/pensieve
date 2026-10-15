import ArgumentParser
import Darwin
import Foundation

struct DeployOptions: ParsableArguments {
    @Option(name: [.short, .long],
        help: "Agent ID; repeat for more. '*' deploys to installed agents; undeploys from installed or intent-bearing agents.")
    var agent: [String] = []
    @Flag(name: [.customShort("g"), .long], help: "Deploy user-wide.") var global = false
    @Option(name: [.short, .long], help: "Registered project name or path; '.' uses this folder.") var project: String?
    @Option(name: [.short, .long], help: "Target Mac name or ID (requires -g); repeat for more.") var machine: [String] = []
    @Flag(help: "Preview changes without applying them.") var dryRun = false
    @Argument(help: "Skill slugs from skill list.") var skills: [String]

    func validate() throws {
        guard !agent.isEmpty else { throw ValidationError("Name an agent with -a (or -a '*').") }
        guard !(global && project != nil) else { throw ValidationError("Choose -g or -p, one scope at a time.") }
        guard machine.isEmpty || global else { throw ValidationError("-m requires -g.") }
    }

    func request(command: String, output: OutputOptions) throws -> CLIRequest {
        var project = project
        var global = global
        if !global && project == nil {
            guard output.canPrompt else {
                throw ValidationError("Choose an explicit scope: -g for this Mac, or -p <project>.")
            }
            FileHandle.standardError.write(Data("Scope: enter g for user-wide, or a registered project name/path: ".utf8))
            guard let scope = readLine(), !scope.isEmpty else { throw ValidationError("Choose -g or -p <project>.") }
            if scope == "g" { global = true } else { project = scope }
        }
        return CLIRequest(command: command, arguments: skills, deployment: CLIDeployOptions(
            agents: agent, global: global, project: project.map { ($0 as NSString).expandingTildeInPath },
            machines: machine, dryRun: dryRun,
            workingDirectory: FileService().realPath(at: ".")))
    }
}

struct DeployCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deploy",
        abstract: "Add skills to selected agents and targets.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var targets: DeployOptions
}

struct UndeployCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "undeploy",
        abstract: "Remove skills from selected agents and targets.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var targets: DeployOptions
}

struct SyncCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Run a sync cycle and return its result.")
    @OptionGroup var output: OutputOptions
    var request: CLIRequest { CLIRequest(command: "sync") }
}
