import Foundation

/// The test advances debounce jobs explicitly; cancellation is checked by the model after resumption.
@MainActor
final class ProjectPreviewDelay {
    private var jobs: [CheckedContinuation<Void, Never>] = []
    private(set) var scheduled = 0

    func wait() async {
        scheduled += 1
        await withCheckedContinuation { jobs.append($0) }
    }

    func advance() {
        let pending = jobs
        jobs = []
        for job in pending { job.resume() }
    }
}
