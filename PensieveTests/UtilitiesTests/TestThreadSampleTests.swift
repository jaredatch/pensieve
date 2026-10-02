import Darwin
import XCTest
@testable import Pensieve

final class TestThreadSampleTests: XCTestCase {
    func testRealSampleContainsStacksAndThreadCensus() {
        let report = TestThreadSample.capture()
        XCTAssertTrue(report.contains("task_threads count="), report)
        XCTAssertTrue(report.contains("sampler wait status=0"), report)
        XCTAssertTrue(report.contains("Call graph:"), report)
        XCTAssertTrue(report.contains("TestThreadSample"), report)
    }

    func testDeadlineKillsAndReapsChildWhileKeepingPartialReport() throws {
        let files = FileService()
        let directory = NSTemporaryDirectory() + "SamplerDeadlineTest-" + UUID().uuidString
        try files.createDirectory(at: directory)
        defer { try? files.deleteDirectory(at: directory) }
        let executable = directory + "/sampler"
        try files.writeExecutableFile(at: executable, content: """
        #!/bin/sh
        printf 'partial sample sentinel' > "$5"
        exec /bin/sleep 60
        """)
        var child: pid_t?
        var ready = false
        var deadlineStarted = 0.0
        defer { if let child { cleanUp(child) } }
        let report = TestThreadSample.capture(executable: executable, timeout: 0.2) { pid, path in
            child = pid
            let startupDeadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < startupDeadline {
                if (try? files.readFile(at: path)) == "partial sample sentinel" { ready = true; break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            deadlineStarted = ProcessInfo.processInfo.systemUptime
        }
        XCTAssertTrue(ready, "Fake sampler must publish its partial report before the deadline starts")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - deadlineStarted, 5)
        XCTAssertTrue(report.contains("killed and reaped"), report)
        XCTAssertTrue(report.contains("partial sample sentinel"), report)
        let pidText = try XCTUnwrap(report.components(separatedBy: "sampler pid=").last?.split(separator: ";").first)
        let pid = try XCTUnwrap(pid_t(pidText))
        XCTAssertEqual(kill(pid, 0), -1, "Timed-out sampler must not survive capture")
        XCTAssertEqual(errno, ESRCH)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, "Capture must reap its child, not leave a zombie")
        XCTAssertEqual(errno, ECHILD)
    }

    private func cleanUp(_ pid: pid_t) {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == 0 else { return }
        kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}
