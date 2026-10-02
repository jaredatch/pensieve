import SwiftData

extension AppRuntime {
    func mainWindowAppeared() async {
        await refreshGitConfiguration(probingGit: false)
    }

    func conflictResolutionDismissed() async {
        await refreshGitConfiguration(probingGit: false)
    }

    var syncStateNotifier: SyncStateNotifying {
        { [weak scheduler] in scheduler?.nudge() }
    }

    var syncWriteEchoRegistrar: SyncWriteEchoRegistering {
        { [weak library] directoryNames in
            library?.noteAppAuthoredBodies(directoryNames: directoryNames)
        }
    }

    var syncBodyWriteRegistration: SyncBodyWriteRegistration {
        SyncBodyWriteRegistration(
            begin: { [weak library] directoryName, expectedBody in
                library?.beginAppAuthoredBodyWrite(
                    directoryName: directoryName, expectedBody: expectedBody
                )
            },
            end: { [weak library] directoryName, succeeded in
                library?.finishAppAuthoredBodyWrite(
                    directoryName: directoryName, succeeded: succeeded
                )
            }
        )
    }

    func installRuntimeCallbacks() {
        syncModel.installPendingSyncRequest { [weak scheduler] in
            scheduler?.enqueueManualTrigger()
        }
        syncModel.installPendingScheduledSyncRequest { [weak scheduler] in
            scheduler?.enqueueTrigger()
        }
        scheduler.installDrain(
            hasRemote: { [weak self] in
                guard let self else { return false }
                return gitUsability == .usable && syncModel.isConfigured
            },
            isConflicted: { [weak syncModel] in syncModel?.isConflicted ?? false },
            action: { [weak syncModel] in await syncModel?.syncScheduledAndReport() }
        )
    }
}
