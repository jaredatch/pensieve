import Darwin
import Foundation
import XCTest
@testable import Pensieve

/// Runs the CLI's external probes outside the test host. The deadline covers the whole probe,
/// including compilers, app launches and Apple events. On expiry, kill its Foundation-created
/// process group and reap the probe within two seconds. The 160 s budget exceeds the desktop
/// probe's 150 s of inner deadlines, with room inside XCTest's 180 s allowance. Children that detach from
/// that group (including LaunchServices apps) are excluded; these probes launch app copies directly.
enum CLIProcessProbe {
    struct Outcome: Sendable {
        let timedOut: Bool
        let status: Int32?
        let pid: pid_t
        let elapsed: TimeInterval
    }

    static func run(_ process: Process, timeout: TimeInterval = 160, readyAt: String? = nil,
                    afterLaunch: () -> Void = {}, beforeCleanup: () -> Void = {},
                    recordTimeout: (String) -> Void = { TestTimeoutDiagnostics.note($0) }) throws -> Outcome {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        afterLaunch()
        let pid = process.processIdentifier
        let group = getpgid(pid)
        let files = FileService()
        let startupDeadline = ProcessInfo.processInfo.systemUptime + 5 // upper-bound: receipt readiness precedes the hang budget
        if let readyAt {
            while !files.fileExists(at: readyAt), process.isRunning,
                  ProcessInfo.processInfo.systemUptime < startupDeadline { Thread.sleep(forTimeInterval: 0.01) }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let startupExpired = readyAt.map { !files.fileExists(at: $0) } ?? false
        let timedOut = startupExpired || exited.wait(timeout: .now() + timeout) == .timedOut
        var reaped = false
        defer {
            if timedOut {
                recordTimeout("CLI process probe timed out: executable=\(process.executableURL?.path ?? "unknown"); " +
                    "pid=\(pid); group=\(group); budget=\(timeout)s; group killed; helper reaped=\(reaped)")
            }
        }
        if timedOut {
            beforeCleanup()
            // Verify ownership at spawn and retain it across the leader's exit and reaping.
            if group == pid { kill(-group, SIGKILL) }
            if process.isRunning { kill(pid, SIGKILL) }
            guard exited.wait(timeout: .now() + 2) == .success else { // upper-bound: reap after SIGKILL, never a success wait
                return Outcome(timedOut: true, status: nil, pid: pid,
                               elapsed: ProcessInfo.processInfo.systemUptime - started)
            }
        }
        reaped = true
        process.terminationHandler = nil
        return Outcome(timedOut: timedOut, status: process.terminationStatus, pid: pid,
                       elapsed: ProcessInfo.processInfo.systemUptime - started)
    }

    static func assertHungProbeIsBounded() throws {
        for exitingLeader in [false, true] { try assertHungProbe(exitingLeader: exitingLeader) }
    }

    private static func assertHungProbe(exitingLeader: Bool) throws {
        let files = FileService()
        let directory = TestTemporaryDirectory.path + "CLIProbe-" + UUID().uuidString
        try files.createDirectory(at: directory)
        defer { try? files.deleteDirectory(at: directory) }
        let receipt = directory + "/child"
        let release = directory + "/exit"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Self-expiry keeps the regression safe even with the old, unbounded waiter. Both the
        // parent and its child ignore TERM so the timeout must actually kill the owned group.
        process.arguments = ["-c", """
        import os, signal, subprocess, sys, time
        time.sleep(\(exitingLeader ? 0 : 1.25))
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = subprocess.Popen([sys.executable, '-c',
            'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(4)'])
        with open(sys.argv[1], 'w') as output: output.write(str(child.pid))
        if \(exitingLeader ? "True" : "False"):
            deadline = time.monotonic() + 4
            while not os.path.exists(sys.argv[2]) and time.monotonic() < deadline: time.sleep(.01)
            os._exit(0)
        child.wait()
        """, receipt, release]
        let result = try run(process, timeout: 1, readyAt: receipt, beforeCleanup: { // upper-bound: before the child's self-exit
            guard exitingLeader else { return }
            do { try files.writeFile(at: release, content: "exit") } catch { XCTFail("cannot release race fixture: \(error)") }
            let deadline = ProcessInfo.processInfo.systemUptime + 2 // upper-bound: reap the leader before group cleanup
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertFalse(process.isRunning, "the race fixture must reap its leader before cleanup")
        })
        XCTAssertTrue(result.timedOut, "a hung probe must fail at its own deadline")
        XCTAssertLessThan(result.elapsed, 3.5)
        XCTAssertEqual(kill(result.pid, 0), -1, "the probe must be reaped before returning")
        let child = try XCTUnwrap(pid_t(files.readFile(at: receipt)))
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size)
        XCTAssertTrue(read == 0 || info.pbi_status == UInt32(SZOMB), "the probe's child must also be stopped")
    }
}
