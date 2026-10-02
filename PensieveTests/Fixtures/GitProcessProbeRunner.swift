import Darwin
import XCTest
@testable import Pensieve

/// Hang-prone git checks run outside XCTest's cooperative pool. Cleanup pauses a live helper,
/// inventories its children plus its recorded child groups, kills that work, then reaps the
/// helper. The registry survives helper crashes; no blocked job can retain the host's pool.
enum GitProcessProbeRunner {
    struct Outcome {
        let status: Int32
        let report: String
        let timedOut: Bool
        let ready: Bool
        let pid: pid_t
        let children: [pid_t]
    }

    static func run(
        _ mode: String, executable: String = "/usr/bin/git", timeout: TimeInterval = 20,
        waitForReady: Bool = false, noteTimeout: Bool = true
    ) throws -> Outcome {
        let files = FileService()
        let directory = NSTemporaryDirectory() + "GitProcessProbe-" + UUID().uuidString
        try files.createDirectory(at: directory)
        defer { try? files.deleteDirectory(at: directory) }
        let report = directory + "/report.txt"
        let childrenDirectory = directory + "/children"
        try files.createDirectory(at: childrenDirectory)
        let process = Process()
        let bundle = Bundle(for: GitServiceConcurrencyTests.self).bundleURL
        process.executableURL = bundle.appendingPathComponent("Contents/MacOS/GitProcessProbe")
        process.arguments = [mode, executable, report]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        var deadline = ProcessInfo.processInfo.systemUptime + (waitForReady ? 10 : timeout)
        var ready = !waitForReady
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            if !ready, (try? files.readFile(at: report)) == "READY" {
                ready = true
                deadline = ProcessInfo.processInfo.systemUptime + timeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        // Stop creation before taking the child inventory. Foundation children have their own
        // groups. The registry also covers a helper that crashed and orphaned its children.
        if process.isRunning { kill(pid, SIGSTOP) }
        let registered = (try? files.listDirectory(at: childrenDirectory)) ?? []
        let children = Set(registered.compactMap { pid_t($0) } + directChildren(of: pid))
        for child in children { kill(-child, SIGKILL); kill(child, SIGKILL) }
        kill(-pid, SIGKILL)
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
        if timedOut && noteTimeout {
            TestTimeoutDiagnostics.note("Git process probe timed out: mode=\(mode); pid=\(pid); group killed; helper reaped")
        }
        return Outcome(status: process.terminationStatus, report: (try? files.readFile(at: report)) ?? "No report",
                       timedOut: timedOut, ready: ready, pid: pid, children: Array(children))
    }

    private static func directChildren(of pid: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return (String(bytes: data, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
        } catch { return [] }
    }

}
