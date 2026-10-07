import Darwin
import XCTest
@testable import Pensieve

final class GitServiceConcurrencyTests: XCTestCase {
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
        }
    }

    func testPipeDrainUsesItsCallersQoS() throws {
        let result = try GitProcessProbeRunner.run("qos")
        XCTAssertEqual(result.status, 0, result.report)
        XCTAssertEqual(result.report, "OK caller and drain QoS")
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
