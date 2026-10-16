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
    @MainActor
    func makeCommandLineSettings() -> CommandLineSettingsModel {
        let live = runtimePaths.isProduction && CLIAppLauncher(fileService: FileService()).launchRefusal(
            appPath: Bundle.main.bundlePath, bundleID: Bundle.main.bundleIdentifier ?? "") == nil
        let installer = CommandLinkInstaller(files: FileService(),
            directory: live ? "/usr/local/bin" : appSupportDir + "/command-line/bin",
            executable: Bundle.main.bundlePath + "/Contents/Helpers/pensieve", user: getuid(),
            homebrewDirectories: live ? ["/opt/homebrew/bin", "/usr/local/bin"] : [],
            authorization: live ? AdminCommandLinkAuthorization() : UnavailableCommandLinkAuthorization(),
            ancestorOwner: live ? 0 : getuid())
        return CommandLineSettingsModel(installer: installer)
    }
}

/// An isolated runtime must never put an authorization prompt on the shared desktop.
private struct UnavailableCommandLinkAuthorization: CommandLinkAuthorizing {
    func run(_ request: CommandLinkRequest) throws {
        throw CommandLinkError(message: "Command installation is unavailable in this isolated runtime.")
    }
}
