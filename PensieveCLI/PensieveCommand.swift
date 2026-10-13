import ArgumentParser

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print one versioned JSON envelope.") var json = false
    @Flag(help: "Disable interactive prompts (also PENSIEVE_NO_INPUT=1).") var noInput = false
    @Option(help: "Read state and connect in an alternate App Support folder.") var appSupport: String?
}

protocol ReadCommand: ParsableCommand {
    var request: CLIRequest { get }
}

struct PensieveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pensieve",
        abstract: "Manage AI skills through Pensieve.",
        subcommands: [SkillCommand.self, SkillsCommand.self, AgentCommand.self, MachineCommand.self,
                      ProjectCommand.self, DeploymentCommand.self, DeployedCommand.self, StatusCommand.self,
                      LogCommand.self, CommandsCommand.self, CompletionCommand.self, VersionCommand.self])
    @OptionGroup var output: OutputOptions
}

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "skill", abstract: "Read the skill library.",
        subcommands: [SkillListCommand.self, SkillShowCommand.self])
    @OptionGroup var output: OutputOptions
}

struct SkillListCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List skills.", aliases: ["ls"])
    @OptionGroup var output: OutputOptions
    var request: CLIRequest { CLIRequest(command: "skill list") }
}

struct SkillsCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "skills", abstract: "Alias for skill list.")
    @OptionGroup var output: OutputOptions
    var request: CLIRequest { CLIRequest(command: "skill list") }
}

struct SkillShowCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show skill metadata.")
    @OptionGroup var output: OutputOptions
    @Argument(help: "The skill's slug from skill list.") var skill: String
    @Flag(help: "Include the skill's untrusted content.") var content = false
    var request: CLIRequest { CLIRequest(command: "skill show", arguments: [skill], content: content) }
}

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent", abstract: "Read installed agents.",
        subcommands: [AgentListCommand.self])
    @OptionGroup var output: OutputOptions
}

struct AgentListCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List agents and canonical IDs.")
    @OptionGroup var output: OutputOptions
    var request: CLIRequest { CLIRequest(command: "agent list") }
}

struct MachineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "machine", abstract: "Read known Macs.",
        subcommands: [MachineListCommand.self])
    @OptionGroup var output: OutputOptions
}

struct MachineListCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List known Macs.")
    @OptionGroup var output: OutputOptions
    var request: CLIRequest { CLIRequest(command: "machine list") }
}

struct ProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "project", abstract: "Read registered projects.",
        subcommands: [ProjectListCommand.self])
    @OptionGroup var output: OutputOptions
}

struct ProjectListCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List registered projects.")
    @OptionGroup var output: OutputOptions
    var request: CLIRequest { CLIRequest(command: "project list") }
}

struct DeploymentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deployment", abstract: "Read recorded deployments.",
        subcommands: [DeploymentListCommand.self])
    @OptionGroup var output: OutputOptions
}

struct DeploymentListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Read deployments from disk.")
    @OptionGroup var output: OutputOptions
}

struct DeployedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deployed", abstract: "Alias for deployment list.")
    @OptionGroup var output: OutputOptions
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Read the last sync result from disk.")
    @OptionGroup var output: OutputOptions
}

struct LogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "Read sync log lines from disk.")
    @OptionGroup var output: OutputOptions
    @Option(help: "Number of recent lines to show.") var lines = 20

    func validate() throws {
        guard lines > 0 else { throw ValidationError("--lines must be a positive integer") }
    }
}

struct CommandsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "commands", abstract: "Describe accepted commands and flags.")
    @OptionGroup var output: OutputOptions
}

struct CompletionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "completion", abstract: "Generate shell completions.")
    @OptionGroup var output: OutputOptions
    @Argument(help: "bash, zsh or fish.") var shell: String

    func validate() throws {
        guard ["bash", "zsh", "fish"].contains(shell) else { throw ValidationError("Choose bash, zsh or fish") }
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Print the app version.")
    @OptionGroup var output: OutputOptions
}
