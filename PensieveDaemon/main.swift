import Foundation

// PensieveDaemon — the background sync daemon executable (PLAN-12) + minimal CLI (PLAN-15).
// Bare invocation (launchd's BundleProgram carries no arguments) runs one sync cycle.
// All parse/dispatch logic lives in DaemonCLI (shared, SwiftData-free, tested from PensieveTests).

let arguments = Array(CommandLine.arguments.dropFirst())

let outcome = DaemonCLI.execute(
    arguments,
    appSupport: PathConstants.pensieveAppSupportDir,
    readFile: { FileManager.default.contents(atPath: $0) },
    runCycle: {
        let fileService = FileService()
        return SyncDaemon(
            root: PathConstants.pensieveBaseDir,
            appSupport: PathConstants.pensieveAppSupportDir,
            git: GitService(),
            credentials: KeychainCredentialStore(),
            reconciler: DeployReconciler(
                fileService: fileService,
                deployState: DeployStateStore(fileService: fileService)
            ),
            now: Date.init
        ).runOnce()
    },
    now: Date.init
)

if !outcome.stdout.isEmpty { FileHandle.standardOutput.write(Data(outcome.stdout.utf8)) }
if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data(outcome.stderr.utf8)) }
exit(outcome.exitCode)
