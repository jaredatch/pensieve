import Darwin
import Foundation

extension AppRuntime {
    func makeBundledSkillModel() -> BundledSkillModel {
        let library = library
        let importer = paths.makeImportViewModel(notifier: { library.notifySyncedStateMutation() },
            echoRegistrar: { library.noteAppAuthoredBodies(directoryNames: $0) })
        return BundledSkillModel(files: FileService(),
            bundledDirectory: Bundle.main.bundlePath + "/Contents/Resources/pensieve",
            receiptPath: paths.appSupportDir + "/pensieve-skill-receipt.json", lockPath: paths.syncLockPath,
            library: library, importer: importer)
    }
}

extension AppRuntimePaths {
    /// Production resolves system paths here. Fixture runtimes stay wholly inside their App Support.
    func makeCommandLinkInstaller() -> CommandLinkInstaller {
        let live = runtimePaths.isProduction && CLIAppLauncher(fileService: FileService()).launchRefusal(
            appPath: Bundle.main.bundlePath, bundleID: Bundle.main.bundleIdentifier ?? "") == nil
        return CommandLinkInstaller(files: FileService(),
            directory: live ? "/usr/local/bin" : appSupportDir + "/command-line/bin",
            executable: Bundle.main.bundlePath + "/Contents/Helpers/pensieve", user: getuid(),
            homebrewDirectories: live ? ["/opt/homebrew/bin", "/usr/local/bin"] : [],
            authorization: live ? AdminCommandLinkAuthorization() : UnavailableCommandLinkAuthorization(),
            ancestorOwner: live ? 0 : getuid())
    }

    @MainActor
    func makeCommandLineSettings() -> CommandLineSettingsModel {
        CommandLineSettingsModel(installer: makeCommandLinkInstaller())
    }
}

/// An isolated runtime must never put an authorization prompt on the shared desktop.
private struct UnavailableCommandLinkAuthorization: CommandLinkAuthorizing {
    func run(_ request: CommandLinkRequest) throws {
        throw CommandLinkError(message: "Command installation is unavailable in this isolated runtime.")
    }
}
