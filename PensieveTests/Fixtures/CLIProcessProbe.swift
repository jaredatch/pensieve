import Darwin
import Foundation
import XCTest
@testable import Pensieve

/// Runs the CLI's external probes outside the test host. The deadline covers the whole probe,
/// including compilers, app launches and Apple events. On expiry, kill its Foundation-created
/// process group and reap the probe within two seconds. Children that deliberately detach from
/// that group (including LaunchServices apps) are excluded; these probes launch app copies directly.
enum CLIProcessProbe {
    struct Outcome: Sendable {
        let timedOut: Bool
        let status: Int32?
        let pid: pid_t
    }

    static func run(_ process: Process, timeout: TimeInterval = 60) throws -> Outcome {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let pid = process.processIdentifier
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            // Foundation gives Process its own group. Never signal the host's group if that
            // assumption stops holding on a future platform.
            if getpgid(pid) == pid { kill(-pid, SIGKILL) }
            kill(pid, SIGKILL)
            guard exited.wait(timeout: .now() + 2) == .success else { // upper-bound: reap after SIGKILL, never a success wait
                return Outcome(timedOut: true, status: nil, pid: pid)
            }
        }
        process.terminationHandler = nil
        return Outcome(timedOut: timedOut, status: process.terminationStatus, pid: pid)
    }

    static func assertHungProbeIsBounded() throws {
        let files = FileService()
        let directory = TestTemporaryDirectory.path + "CLIProbe-" + UUID().uuidString
        try files.createDirectory(at: directory)
        defer { try? files.deleteDirectory(at: directory) }
        let receipt = directory + "/child"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Self-expiry keeps the regression safe even with the old, unbounded waiter. Both the
        // parent and its child ignore TERM so the timeout must actually kill the owned group.
        process.arguments = ["-c", """
        import os, signal, subprocess, sys
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = subprocess.Popen([sys.executable, '-c',
            'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(4)'])
        with open(sys.argv[1], 'w') as output: output.write(str(child.pid))
        child.wait()
        """, receipt]
        let started = ProcessInfo.processInfo.systemUptime
        let result = try run(process, timeout: 1) // upper-bound: expire before the broken waiter's four-second self-exit
        XCTAssertTrue(result.timedOut, "a hung probe must fail at its own deadline")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3.5)
        XCTAssertEqual(kill(result.pid, 0), -1, "the probe must be reaped before returning")
        let child = try XCTUnwrap(pid_t(files.readFile(at: receipt)))
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size)
        XCTAssertTrue(read == 0 || info.pbi_status == UInt32(SZOMB), "the probe's child must also be stopped")
    }
}
