import SwiftData

extension AppRuntime {
    func makeUpdatesModel() -> UpdatesViewModel {
        UpdatesViewModel(rowLoader: updatesViewModelOperations.rowLoader,
                        applyOperation: updatesViewModelOperations.applyOperation,
                        recheckOperation: updatesViewModelOperations.recheckOperation,
                        notifier: syncStateNotifier, echoRegistrar: syncWriteEchoRegistrar,
                        bodyWriteRegistration: syncBodyWriteRegistration)
    }

    func makeViewChangesModel() -> ViewChangesViewModel {
        ViewChangesViewModel(library: library, operations: UpdateReviewOperations(
            diffOperation: updatesViewModelOperations.diffOperation,
            recheckOperation: updatesViewModelOperations.recheckOperation
        ), updates: updates)
    }

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
        syncModel.installPendingSyncRequest { [weak scheduler] request in
            scheduler?.enqueue(request)
        }
        scheduler.installDrain(
            isConfigured: { [weak self] in
                guard let self else { return false }
                return syncModel.isConfigured
            },
            isGitUsable: { [weak self] in self?.gitUsability == .usable },
            isConflicted: { [weak syncModel] in syncModel?.isConflicted ?? false },
            action: { [weak syncModel, weak scheduler] request in
                await syncModel?.syncAndReport(request, onCycleStart: { scheduler?.cycleDidStart() })
            }
        )
    }
}
