import Darwin
import XCTest
@testable import Pensieve

final class GitServiceConcurrencyTests: XCTestCase {
    func testGitExitReturnsItsOutputWhileDetachedPipeHoldersRemainAlive() throws {
        for pipe in ["stdout", "stderr"] {
            for behavior in ["sleeping", "writing"] {
                let result = try GitProcessProbeRunner.run("holder-\(pipe)-\(behavior)",
                                                           timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
                XCTAssertFalse(result.timedOut, "git exit must bound the call: \(pipe), \(behavior)")
                XCTAssertEqual(result.status, 0, result.report)
                XCTAssertEqual(result.report, "OK output, status; holder alive")
            }
        }
        for mode in ["holder-stdout-sleeping-partial", "holder-stderr-sleeping-partial"] {
            let result = try GitProcessProbeRunner.run(mode, timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
            XCTAssertFalse(result.timedOut, mode)
            XCTAssertEqual(result.status, 0, "\(mode): \(result.report)")
            XCTAssertEqual(result.report, "OK output, status; holder alive")
        }
        let exiting = try GitProcessProbeRunner.run("exit-watch-esrch",
                                                   timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
        XCTAssertFalse(exiting.timedOut, "An exiting child must finish without an exit watch")
        XCTAssertEqual(exiting.status, 0, exiting.report)
        XCTAssertEqual(exiting.report, "OK exiting child; output, status; holder alive; git reaped")
    }

    func testGitExitWakesReaderAfterEOFIncludingAnAlreadyQueuedExit() throws {
        for mode in ["exit-wake", "exit-wake-queued", "exit-wake-eintr"] {
            let result = try GitProcessProbeRunner.run(mode, timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
            XCTAssertFalse(result.timedOut, mode)
            XCTAssertEqual(result.status, 0, "\(mode): \(result.report)")
            XCTAssertEqual(result.report, "OK exit wake; waits=1; empty output, status")
        }
    }

    func testBlockedCallsBeyondCoreCountAllowAnotherSamePriorityGitCall() throws {
        let result = try GitProcessProbeRunner.run("blocking", timeout: 45, strictPool: true)
        XCTAssertFalse(result.timedOut, "The off-pool watchdog must judge progress and clean up")
        XCTAssertEqual(result.status, 0, result.report)
        XCTAssertEqual(result.report, "OK blocked=\(ProcessInfo.processInfo.activeProcessorCount + 1); extra git completed")
    }

    func testBothPipesDrainBeyondTheirBufferCapacity() throws {
        let files = FileService()
        let directory = TestTemporaryDirectory.path + "GitPipeDrainTest-" + UUID().uuidString
        try files.createDirectory(at: directory)
        defer { try? files.deleteDirectory(at: directory) }
        let executable = directory + "/git"
        try files.writeExecutableFile(at: executable, content: """
        #!/bin/sh
        /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\000' E >&2
        /usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\000' O
        exit 23
        """)
        let result = try GitProcessProbeRunner.run("pipes", executable: executable)
        XCTAssertFalse(result.timedOut, "Both full pipes must keep draining")
        XCTAssertEqual(result.status, 0, result.report)
        XCTAssertEqual(result.report, "OK both pipes")
    }

    func testUtilityTasksCanRunMoreGitCommandsThanThereAreCores() throws {
        let result = try GitProcessProbeRunner.run("concurrency")
        XCTAssertFalse(result.timedOut, "Synchronous git drains must progress when cooperative callers fill the pool")
        XCTAssertEqual(result.status, 0, result.report)
        let count = max(64, ProcessInfo.processInfo.activeProcessorCount * 4)
        XCTAssertEqual(result.report, "OK probes=\(count)")
    }

    func testPipeReadFailuresThrowAndReapTheChild() throws {
        let files = FileService()
        let directory = TestTemporaryDirectory.path + "GitReadFailureTest-" + UUID().uuidString
        try files.createDirectory(at: directory)
        defer { try? files.deleteDirectory(at: directory) }
        let executable = directory + "/git"
        try files.writeExecutableFile(at: executable, content: "#!/bin/sh\nexec /bin/sleep 60\n")
        for pipe in ["stdout", "stderr"] {
            let result = try GitProcessProbeRunner.run(pipe, executable: executable, timeout: TestWait.hostedActionTimeoutSeconds)
            XCTAssertFalse(result.timedOut, "Read failure must terminate and join: \(pipe)")
            XCTAssertEqual(result.status, 0, "\(pipe): \(result.report)")
            XCTAssertEqual(result.report, "OK read error; child reaped")
            for mode in ["group-\(pipe)", "group-\(pipe)-partial"] {
                let group = try GitProcessProbeRunner.run(mode,
                                                       timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
                XCTAssertFalse(group.timedOut, "Read failure must stop git and its helper: \(mode)")
                XCTAssertEqual(group.status, 0, "\(mode): \(group.report)")
                XCTAssertEqual(group.report, "OK read error; git and helper stopped; git reaped")
            }
        }
        let conflict = try GitProcessProbeRunner.run("conflict-read",
                                                  timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
        XCTAssertFalse(conflict.timedOut)
        XCTAssertEqual(conflict.status, 0, conflict.report)
        XCTAssertEqual(conflict.report, "OK read error; child reaped", "Best-effort conflict blobs must propagate pipe failures")
        for mode in ["usability-read", "confirmation-read"] {
            let result = try GitProcessProbeRunner.run(mode, timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
            XCTAssertFalse(result.timedOut, mode)
            XCTAssertEqual(result.status, 0, "\(mode): \(result.report)")
            XCTAssertEqual(result.report, "OK probe read error; child reaped")
        }
        for mode in ["reap-exit-failure", "reap-cleanup-failure"] {
            let result = try GitProcessProbeRunner.run(mode, timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
            XCTAssertFalse(result.timedOut, mode)
            XCTAssertEqual(result.status, 0, "\(mode): \(result.report)")
            XCTAssertEqual(result.report, mode == "reap-exit-failure" ? "OK reap error; group helper alive"
                           : "OK cleanup reap error stays local")
        }
    }

    func testReadFailureAfterGitExitReturnsWhileDetachedStderrHolderLives() throws {
        let result = try GitProcessProbeRunner.run("holder-after-exit-failure",
                                                timeout: TestWait.hostedActionTimeoutSeconds, noteTimeout: false)
        XCTAssertFalse(result.timedOut, "The failed stdout read must not join the inherited stderr pipe")
        XCTAssertEqual(result.status, 0, result.report)
        XCTAssertEqual(result.report, "OK read error after exit; holder alive")
    }

    func testPipeDrainUsesItsCallersQoS() throws {
        let result = try GitProcessProbeRunner.run("qos")
        XCTAssertEqual(result.status, 0, result.report)
        XCTAssertEqual(result.report, "OK caller and drain QoS")
        let signals = try GitProcessProbeRunner.run("spawn-signals", timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertFalse(signals.timedOut)
        XCTAssertEqual(signals.status, 0, signals.report)
        XCTAssertEqual(signals.report, "OK child signals; blocked caller")
        let terminal = try GitProcessProbeRunner.run("spawn-terminal", timeout: TestWait.hostedActionTimeoutSeconds)
        XCTAssertFalse(terminal.timedOut)
        XCTAssertEqual(terminal.status, 0, terminal.report)
        XCTAssertEqual(terminal.report, "OK child session and group; no controlling terminal; foreground caller")
    }

    func testTimedOutProbeDoesNotPoisonNextProbe() throws {
        let result = try GitProcessProbeRunner.run("hold", timeout: 0.2, // upper-bound: Exercise timed-out child cleanup.
                                                   waitForReady: true, noteTimeout: false)
        XCTAssertTrue(result.ready, "The child must be running before the timeout starts")
        XCTAssertTrue(result.timedOut)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(result.pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        XCTAssertFalse(result.children.isEmpty, "The timeout must cover a live child")
        defer {
            for child in result.children { kill(-child, SIGKILL); kill(child, SIGKILL) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while result.children.contains(where: { kill($0, 0) == 0 }) && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { kill(-result.pid, SIGKILL) }
        XCTAssertEqual(kill(-result.pid, 0), -1)
        for child in result.children {
            XCTAssertEqual(kill(child, 0), -1, "Timeout cleanup must remove the helper's children too")
        }
        let next = try GitProcessProbeRunner.run("concurrency")
        XCTAssertFalse(next.timedOut, "A timed-out helper must not starve its neighbour")
        XCTAssertEqual(next.status, 0, next.report)
    }
}
