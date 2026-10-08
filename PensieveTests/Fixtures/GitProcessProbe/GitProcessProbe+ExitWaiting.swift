import Darwin
import Foundation

extension GitProcessProbe {
    /// Hold the real child alive until the registration failure has observed it as not waitable.
    /// Then allow exit. The injected kernel error is deterministic; output and lifetime are real.
    static func exitingChildWithoutWatch() -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let files = FileService()
        let executable = root + "/exiting-git"
        do {
            try files.writeExecutableFile(at: executable, content: """
            #!/usr/bin/python3
            import os, time
            child = os.fork()
            if child == 0:
                os.setsid()
                os.close(1)
                with open('\(root)/children/' + str(os.getpid()), 'w') as f: f.write('holder')
                with open('\(root)/holder', 'w') as f: f.write(str(os.getpid()))
                while True: time.sleep(1)
            os.write(1, b'O' * 128)
            os.write(2, b'E' * 128)
            while not os.path.exists('\(root)/exit'): time.sleep(0.0001)
            os._exit(23)
            """)
            var child: pid_t = 0
            var holder: pid_t = 0
            var admitted = false
            var finalReads = 0
            let service = git(executable, started: { child = $0 }, beforeExitWatch: { _ in
                holder = try readPID(at: root + "/holder")
                throw GitProcess.posixError(ESRCH)
            }, exitWatchFailed: { _, error, exited in
                guard (error as NSError).code == Int(ESRCH), !exited else {
                    throw GitProcess.posixError(EINVAL)
                }
                admitted = true
                try files.writeFile(at: root + "/exit", content: "exit")
            }, beforeRead: { pid, _, _, exited in
                var info = siginfo_t()
                guard exited, waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0,
                      info.si_pid == pid else { throw GitProcess.posixError(ECHILD) }
                finalReads += 1
            })
            let output = try service.runData(["--version"], in: nil)
            var status: Int32 = 0
            let reaped = waitpid(child, &status, WNOHANG) == -1 && errno == ECHILD
            let intact = output.stdout == Data(repeating: 79, count: 128)
                && output.stderr == Data(repeating: 69, count: 128) && output.exit == 23
            return admitted && finalReads == 2 && reaped && intact && kill(holder, 0) == 0
                ? "OK exiting child; output, status; holder alive; git reaped" : "FAIL exit-watch lifetime or output"
        } catch { return "FAIL exit-watch ESRCH: \(error)" }
    }

    /// Keep git alive after both EOFs. Only its exit can produce a readiness event then.
    /// Count completed kernel waits, excluding EINTR, and distinguish timed-out waits (zero events).
    /// The child’s idle interval supplies the stimulus; scheduling delays cannot break the assertion.
    static func exitWake(_ mode: String) -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let files = FileService()
        let base = root + "/exit-wake"
        let executable = base + "-git"
        do {
            try files.writeExecutableFile(at: executable, content: """
            #!/usr/bin/python3
            import os, time
            os.close(1)
            os.close(2)
            with open('\(base).ready', 'w') as f: f.write('ready')
            while not os.path.exists('\(base).wait'): time.sleep(0.0001)
            time.sleep(\(mode == "exit-wake-queued" ? "0" : "0.1"))
            os._exit(23)
            """)
            let observer = ExitWakeObserver()
            let service = git(executable, hooks: { hooks in
                observer.configure(&hooks, mode: mode, base: base, files: files)
            }, beforeRead: { _, _, stdout, exited in
                guard stdout, !exited else { return }
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while !files.fileExists(at: base + ".ready"), ProcessInfo.processInfo.systemUptime < deadline {
                    usleep(100)
                }
                guard files.fileExists(at: base + ".ready") else { throw GitProcess.posixError(ETIMEDOUT) }
            })
            let output = try service.runData(["--version"], in: nil)
            guard observer.admitted, output.exit == 23, output.stdout.isEmpty, output.stderr.isEmpty else {
                return "FAIL EOF/exit admission or output"
            }
            return observer.result(mode)
        } catch { return "FAIL \(error)" }
    }
}

private final class ExitWakeObserver {
    private(set) var admitted = false
    private var waits = 0
    private var timeouts = 0
    private var interrupted = false

    func configure(_ hooks: inout GitProcessProbeHooks, mode: String, base: String, files: FileService) {
        hooks.beforeWait = { pid, bothEOF in
            guard bothEOF else { throw GitProcess.posixError(EINVAL) }
            if !self.admitted {
                self.admitted = true
                try files.writeFile(at: base + ".wait", content: "waiting")
                if mode == "exit-wake-queued" { try GitProcessProbe.waitForUnreapedExit(pid) }
            }
        }
        hooks.waitFailure = {
            guard mode == "exit-wake-eintr", !self.interrupted else { return nil }
            self.interrupted = true
            return EINTR
        }
        hooks.waitReturned = { count in
            if count >= 0 { self.waits += 1 }
            if count == 0 { self.timeouts += 1 }
            errno = EBADF
        }
    }

    func result(_ mode: String) -> String {
        waits == 1 && (mode != "exit-wake-eintr" || interrupted)
            ? "OK exit wake; waits=1; empty output, status"
            : "FAIL exit wake; waits=\(waits), timeout wakes=\(timeouts)"
    }
}
