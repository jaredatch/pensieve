import Foundation

// PensieveDaemon — the background sync daemon executable (PLAN-12) + minimal CLI (PLAN-15).
// Subcommands only: `run` syncs; a bare invocation prints usage.
// All parse/dispatch logic lives in DaemonCLI (shared, SwiftData-free, tested from PensieveTests).

let paths = RuntimePaths.production
let arguments = Array(CommandLine.arguments.dropFirst())

let outcome = DaemonCLI.execute(
    arguments,
    appSupport: paths.appSupportDir,
    readFile: { try? FileService().readData(at: $0) },
    runCycle: {
        let fileService = FileService()
        let git = paths.makeGitService(fileService: fileService)
        return SyncDaemon(
            root: paths.storeRoot,
            appSupport: paths.appSupportDir,
            git: git,
            hasLocalBranches: git.hasLocalBranches,
            credentials: paths.credentialStore,
            reconciler: paths.makeDeployReconciler(fileService: fileService),
            now: Date.init
        ).runOnce()
    },
    now: Date.init
)

if !outcome.stdout.isEmpty { FileHandle.standardOutput.write(Data(outcome.stdout.utf8)) }
if !outcome.stderr.isEmpty { FileHandle.standardError.write(Data(outcome.stderr.utf8)) }
exit(outcome.exitCode)
