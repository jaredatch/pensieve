import Darwin
import Foundation

/// Disposable test executable; links the production runner, never the app runtime. It registers
/// Foundation's separate child process groups so XCTest can remove all work after a deadlock.
@main
enum GitProcessProbe {
    private static var registry = ""

    static func main() {
        guard CommandLine.arguments.count == 4 else { exit(64) }
        if getpgrp() != getpid(), setpgid(0, 0) != 0 { exit(70) }
        let mode = CommandLine.arguments[1]
        let executable = CommandLine.arguments[2]
        let report = CommandLine.arguments[3]
        registry = (report as NSString).deletingLastPathComponent + "/children"
        if mode == "hold" {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["60"]
            do {
                try child.run()
                record(child)
                try FileService().writeFile(at: report, content: "READY")
                child.waitUntilExit()
            } catch { exit(74) }
            exit(1)
        }
        let text = run(mode, executable: executable)
        do { try FileService().writeFile(at: report, content: text) } catch { exit(74) }
        exit(text.hasPrefix("OK") ? 0 : 1)
    }

    private static func record(_ child: Process) {
        do {
            try FileService().writeFile(at: registry + "/\(child.processIdentifier)", content: "child")
        } catch {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            exit(74)
        }
    }

    static func run(_ mode: String, executable: String) -> String {
        if mode == "concurrency" {
            let count = max(64, ProcessInfo.processInfo.activeProcessorCount * 4)
            let state = ProbeResults()
            let completed = DispatchGroup()
            for _ in 0..<count {
                completed.enter()
                Task.detached(priority: .utility) {
                    // Exact production probe path, including its default executable and pipe reader.
                    state.record(GitService(processStarted: record).probeUsability() == .usable)
                    completed.leave()
                }
            }
            completed.wait()
            return state.successes == count ? "OK probes=\(count)" : "FAIL probes=\(state.successes)/\(count)"
        }
        if mode == "pipes" {
            do {
                let output = try GitService(executablePath: executable, processStarted: record).runData(["--version"], in: nil)
                let intact = output.stdout == Data(repeating: 79, count: 262_144)
                    && output.stderr == Data(repeating: 69, count: 262_144) && output.exit == 23
                return intact ? "OK both pipes" : "FAIL pipe payload or status"
            } catch { return "FAIL \(error)" }
        }
        return fault(mode, executable: executable)
    }

    static func fault(_ mode: String, executable: String) -> String {
        let io = GitService.ProcessIO()
        if mode == "qos" { return qos(io: io) }
        do {
            try (mode == "stdout" ? io.stdout : io.stderr).fileHandleForReading.close()
            _ = try GitService(executablePath: executable, processStarted: record).runData(["--version"], in: nil, io: io)
            return "FAIL missing read error"
        } catch is GitError {
            let pid = io.process.processIdentifier
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            let reaped = waited == -1 && errno == ECHILD
            return !io.process.isRunning && reaped ? "OK read error; child reaped" : "FAIL live child or zombie"
        } catch { return "FAIL wrong error: \(error)" }
    }

    static func qos(io original: GitService.ProcessIO) -> String {
        let done = DispatchGroup()
        let state = ProbeResults()
        done.enter()
        let caller = Thread {
            var io = original
            io.read = { handle in
                state.record(Thread.current.qualityOfService == .utility)
                return try handle.readToEnd()
            }
            do {
                _ = try GitService(processStarted: record).runData(["--version"], in: nil, io: io)
            } catch { state.record(false) }
            done.leave()
        }
        caller.qualityOfService = .utility
        caller.start()
        done.wait()
        return state.successes == 2 ? "OK caller and drain QoS" : "FAIL caller/drain QoS matches=\(state.successes)"
    }
}

private final class ProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var successes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func record(_ success: Bool) { lock.lock(); defer { lock.unlock() }; if success { count += 1 } }
}
