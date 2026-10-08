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
                record(child.processIdentifier)
                try FileService().writeFile(at: report, content: "READY")
                child.waitUntilExit()
            } catch { exit(74) }
            exit(1)
        }
        let text = run(mode, executable: executable)
        do { try FileService().writeFile(at: report, content: text) } catch { exit(74) }
        exit(text.hasPrefix("OK") ? 0 : 1)
    }

    static func record(_ pid: pid_t) {
        do {
            try FileService().writeFile(at: registry + "/\(pid)", content: "child")
        } catch {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            exit(74)
        }
    }

    static func git(_ executable: String = "/usr/bin/git", started: ((pid_t) -> Void)? = nil,
                    beforeExitWatch: ((pid_t) throws -> Void)? = nil,
                    exitWatchFailed: GitProcessProbeHooks.ExitWatchFailed? = nil,
                    beforeRead: GitProcessProbeHooks.BeforeRead? = nil) -> GitService {
        var service = GitService(executablePath: executable)
        service.probeHooks = GitProcessProbeHooks(started: { pid in record(pid); started?(pid) },
                                                 beforeRead: beforeRead ?? { _, _, _, _ in },
                                                 beforeExitWatch: beforeExitWatch,
                                                 exitWatchFailed: exitWatchFailed)
        return service
    }

    static func run(_ mode: String, executable: String) -> String {
        if mode == "spawn-signals" { return spawnSignals() }
        if mode == "exit-wake" { return exitWake() }
        if mode == "exit-watch-esrch" { return exitingChildWithoutWatch() }
        if mode == "usability-read" || mode == "confirmation-read" { return usabilityRead(mode) }
        if mode.hasPrefix("holder-") { return holder(mode) }
        if mode.hasPrefix("group-") { return groupFailure(mode) }
        if mode == "blocking" { return blocking(executable: executable) }
        if mode == "concurrency" { return concurrency() }
        if mode == "pipes" {
            do {
                let output = try git(executable).runData(["--version"], in: nil)
                let intact = output.stdout == Data(repeating: 79, count: 262_144)
                    && output.stderr == Data(repeating: 69, count: 262_144) && output.exit == 23
                return intact ? "OK both pipes" : "FAIL pipe payload or status"
            } catch { return "FAIL \(error)" }
        }
        return fault(mode, executable: executable)
    }

    static func concurrency() -> String {
        let count = max(64, ProcessInfo.processInfo.activeProcessorCount * 4)
        let state = ProbeResults()
        let completed = DispatchGroup()
        for index in 0..<count {
            completed.enter()
            BlockingWork.task(priority: .utility) {
                // Exact production probe path, including its default executable and pipe reader.
                var registration = ""
                let service = git(exitWatchFailed: { pid, error, exited in
                    let error = error as NSError
                    registration = "exit-watch registration pid=\(pid) \(error.domain)/\(error.code), waitable=\(exited)"
                })
                do {
                    let usability = try service.probeUsability()
                    state.record(usability == .usable, failure: "call \(index): \(usability)")
                } catch {
                    state.record(false, failure: "call \(index): \(error); \(registration)")
                }
                completed.leave()
            }
        }
        completed.wait()
        return state.successes == count ? "OK probes=\(count)"
            : "FAIL probes=\(state.successes)/\(count)\n" + state.failureDetails.joined(separator: "\n")
    }

    static func fault(_ mode: String, executable: String) -> String {
        if mode == "qos" { return qos() }
        var child: pid_t = 0
        let service = git(executable) { pid, descriptor, stdout, _ in
            child = pid
            if mode == "conflict-read" || stdout == (mode == "stdout") { close(descriptor) }
        }
        do {
            if mode == "conflict-read" {
                let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
                _ = try service.blob(atStage: 2, path: "missing", in: root)
            } else {
                _ = try service.runData(["--version"], in: nil)
            }
            return "FAIL missing read error"
        } catch GitError.outputReadFailed {
            var status: Int32 = 0
            let reaped = waitpid(child, &status, WNOHANG) == -1 && errno == ECHILD
            return kill(child, 0) == -1 && reaped ? "OK read error; child reaped" : "FAIL live child or zombie"
        } catch { return "FAIL wrong error: \(error)" }
    }

    static func qos() -> String {
        let done = DispatchGroup()
        let state = ProbeResults()
        done.enter()
        let caller = Thread {
            let callerID = pthread_self()
            let service = git(beforeRead: { _, _, _, _ in
                state.record(Thread.current.qualityOfService == .utility && pthread_equal(callerID, pthread_self()) != 0)
            })
            do { _ = try service.runData(["--version"], in: nil) } catch { state.record(false) }
            done.leave()
        }
        caller.qualityOfService = .utility
        caller.start()
        done.wait()
        return state.successes >= 2 && state.failures == 0
            ? "OK caller and drain QoS" : "FAIL caller/drain QoS matches=\(state.successes), failures=\(state.failures)"
    }

}

private final class ProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failed = 0
    private var errors: [String] = []
    var successes: Int { lock.lock(); defer { lock.unlock() }; return count }
    var failures: Int { lock.lock(); defer { lock.unlock() }; return failed }
    var failureDetails: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func record(_ success: Bool, failure: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if success { count += 1 } else {
            failed += 1
            if let failure { errors.append(failure) }
        }
    }
}
