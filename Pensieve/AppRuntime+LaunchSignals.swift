import Foundation

extension AppRuntime {
    func completeLaunchWorkIfPossible() {
        guard didCompleteLaunchIngest, didFinishInitialLaunchCallbacks else { return }
        launchWorkCompleted = true
    }

    func signalLaunchIngestIfPossible() {
        guard didCompleteLaunchIngest,
              !didSignalLaunchIngest,
              let coordinator else { return }
        didSignalLaunchIngest = true
        let stamp = launchIngestHeadStamp
        Task { [weak self] in
            await coordinator.seedLastIngestedHeadStamp(stamp)
            guard let self else { return }
            if self.forceLaunchPreflight {
                self.forceLaunchPreflight = false
                self.scheduler.enqueueManualTrigger()
            }
            self.scheduler.launchIngestCompleted()
        }
    }
}
