import ArgumentParser
import Foundation

struct ConfirmationOptions: ParsableArguments {
    @Flag(help: "Preview changes without applying them.") var dryRun = false
    @Flag(help: "Confirm this action without prompting.") var yes = false
    @Option(help: "Apply only the exact plan carrying this confirmation token.") var confirmPlan: String?
}

struct InstallCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install skills from GitHub.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var confirmation: ConfirmationOptions
    @Argument(help: "GitHub repository or skill URL.") var url: String
    @Option(help: "Select a skill by its discovered slug; repeat for more.") var skill: [String] = []
    @Flag(help: "Use the first available numbered slug for collisions.") var rename = false
    @Flag(help: "Skip colliding skills.") var skip = false
    func validate() throws {
        guard !(rename && skip) else { throw ValidationError("Choose --rename or --skip.") }
    }
    var request: CLIRequest {
        CLIRequest(command: "install", arguments: [url], library: CLILibraryOptions(
            dryRun: confirmation.dryRun, confirmed: confirmation.yes,
            confirmationToken: confirmation.confirmPlan, skills: skill, rename: rename, skip: skip))
    }
}

struct SkillOutdatedCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "outdated", abstract: "Check upstream for skill updates.")
    @OptionGroup var output: OutputOptions
    var request: CLIRequest { CLIRequest(command: "skill outdated") }
}

struct SkillUpdateCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Apply verified skill updates.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var confirmation: ConfirmationOptions
    @Argument(help: "Skill slugs from skill list.") var skills: [String]
    @Flag(help: "Allow replacing local file edits; unsaved editor drafts still refuse.") var overwriteLocalChanges = false
    var request: CLIRequest {
        CLIRequest(command: "skill update", arguments: skills, library: CLILibraryOptions(
            dryRun: confirmation.dryRun, confirmed: confirmation.yes,
            confirmationToken: confirmation.confirmPlan, overwriteLocalChanges: overwriteLocalChanges))
    }
}

struct SkillDeleteCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a skill and its deployments.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var confirmation: ConfirmationOptions
    @Argument(help: "Skill slug from skill list.") var skill: String
    var request: CLIRequest {
        CLIRequest(command: "skill delete", arguments: [skill], library: CLILibraryOptions(
            dryRun: confirmation.dryRun, confirmed: confirmation.yes,
            confirmationToken: confirmation.confirmPlan))
    }
}

struct ProjectAddCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Register a local project folder.")
    @OptionGroup var output: OutputOptions
    @Argument(help: "Project folder path.") var path: String
    @Option(help: "Project display name; defaults to the folder name.") var name: String?
    @Flag(help: "Preview registration without writing an identity marker or saving.") var dryRun = false
    var request: CLIRequest {
        CLIRequest(command: "project add", arguments: [(path as NSString).expandingTildeInPath],
            library: CLILibraryOptions(dryRun: dryRun, name: name, workingDirectory: FileService().realPath(at: ".")))
    }
}

struct ProjectRemoveCommand: ReadCommand {
    static let configuration = CommandConfiguration(commandName: "remove",
        abstract: "Unregister a project and remove owned deployments.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var confirmation: ConfirmationOptions
    @Argument(help: "Registered project name or path.") var project: String
    var request: CLIRequest {
        CLIRequest(command: "project remove", arguments: [(project as NSString).expandingTildeInPath],
            library: CLILibraryOptions(dryRun: confirmation.dryRun, confirmed: confirmation.yes,
            confirmationToken: confirmation.confirmPlan,
                workingDirectory: FileService().realPath(at: ".")))
    }
}
