import Darwin
import Foundation

extension GitProcessProbe {
    /// The real runner executes a process with a live helper in its group. The outer probe
    /// watchdog cleans up a regression; no fixture supplies the cancellation or reap behavior.
    static func cancellation(_ mode: String) -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let files = FileService()
        let executable = root + "/cancellation-git"
        let readOnly = mode == "cancel-read"
        let done = DispatchSemaphore(value: 0)
        let result = CancellationResult()
        do {
            try writeCancellationGit(at: executable, root: root)
            let worker = BlockingWork.task {
                defer { done.signal() }
                do {
                    let output = try GitCancellation.$isReadOnly.withValue(readOnly) {
                        try git(executable).runData(["--version"], in: nil)
                    }
                    result.set(output.exit == 0 && String(data: output.stdout, encoding: .utf8) == "finished write\n"
                        ? "completed" : "wrong output")
                } catch is CancellationError { result.set("cancelled") } catch { result.set("wrong error: \(error)") }
            }
            let parent = try readPID(at: root + "/parent")
            let helper = try readPID(at: root + "/helper")
            record(helper)
            guard getpgid(parent) == parent, getpgid(helper) == parent,
                  kill(parent, 0) == 0, kill(helper, 0) == 0 else { return "FAIL fixture not live" }
            worker.cancel()
            if !readOnly {
                guard done.wait(timeout: .now() + 0.15) == .timedOut, // upper-bound: Observe the held write.
                      kill(parent, 0) == 0, kill(helper, 0) == 0 else { return "FAIL write interrupted" }
                try files.writeFile(at: root + "/release", content: "finish")
            }
            guard done.wait(timeout: .now() + 5) == .success else { // upper-bound: The outer watchdog owns cleanup.
                return "FAIL cancellation did not join"
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while kill(helper, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline { usleep(1_000) }
            var status: Int32 = 0
            let reaped = waitpid(parent, &status, WNOHANG) == -1 && errno == ECHILD
            guard reaped, kill(parent, 0) == -1, kill(helper, 0) == -1 else { return "FAIL processes survived" }
            return result.value == (readOnly ? "cancelled" : "completed")
                ? "OK \(readOnly ? "cancelled read" : "finished write"); group stopped; child reaped"
                : "FAIL \(result.value)"
        } catch { return "FAIL \(error)" }
    }
    private static func writeCancellationGit(at executable: String, root: String) throws {
        try FileService().writeExecutableFile(at: executable, content: """
            #!/usr/bin/python3
            import os, time
            child = os.fork()
            if child == 0:
                with open('\(root)/helper', 'w') as f: f.write(str(os.getpid()))
                while not os.path.exists('\(root)/release'): time.sleep(0.005)
                os._exit(0)
            with open('\(root)/parent', 'w') as f: f.write(str(os.getpid()))
            os.waitpid(child, 0)
            print('finished write')
            """)
    }
}

private final class CancellationResult: @unchecked Sendable {
    // The probe's worker publishes under this lock before signalling its completion.
    private let lock = NSLock()
    private var result = "pending"
    var value: String { lock.lock(); defer { lock.unlock() }; return result }
    func set(_ value: String) { lock.lock(); defer { lock.unlock() }; result = value }
}
