import Foundation

extension GitProcessProbe {
    /// The process main thread observes child-written readiness and judges the extra git call.
    /// It releases the blocked children on either verdict; no watchdog job uses Swift's pool.
    static func blocking(executable: String) -> String {
        let files = FileService()
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let ready = root + "/ready"
        let release = root + "/release"
        let fakeGit = root + "/git"
        let count = ProcessInfo.processInfo.activeProcessorCount + 1
        do {
            try files.createDirectory(at: ready)
            try files.writeExecutableFile(at: fakeGit, content: """
            #!/bin/sh
            : > '\(ready)/'$$
            while [ ! -f '\(release)' ]; do /bin/sleep 0.01; done
            printf 'git version fixture\\n'
            """)
        } catch { return "FAIL fixture: \(error)" }
        let state = BlockingProbeResults()
        let workers = (0..<count).map { _ in
            BlockingWork.task(priority: .utility) {
                state.record((try? git(fakeGit).probeUsability()) == .usable)
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ((try? files.listDirectory(at: ready).count) ?? 0) < count
            && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let blocked = ((try? files.listDirectory(at: ready).count) ?? 0) == count
        let extra = DispatchSemaphore(value: 0)
        if blocked {
            BlockingWork.task(priority: .utility) {
                if (try? git(executable).probeUsability()) == .usable {
                    extra.signal()
                }
            }
        }
        let progressed = blocked && extra.wait(timeout: .now() + 15) == .success
        do { try files.writeFile(at: release, content: "release") } catch { return "FAIL release: \(error)" }
        let joined = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            for worker in workers { await worker.value }
            joined.signal()
        }
        guard joined.wait(timeout: .now() + 15) == .success else { return "FAIL joining blocked git" }
        guard progressed && state.successes == count else {
            return "FAIL blocked=\(blocked); extra=\(progressed); completed=\(state.successes)/\(count)"
        }
        return "OK blocked=\(count); extra git completed"
    }
}

/// Counts worker outcomes without making a worker report an XCTest issue.
private final class BlockingProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var successes: Int { lock.withLock { count } }
    func record(_ success: Bool) { lock.withLock { if success { count += 1 } } }
}
