import Darwin
import Foundation

extension GitProcessProbe {
    /// Hold the other pipe in git's group, prove both processes are live, then fail one read.
    /// Observe liveness after the runner returns. The outer watchdog owns cleanup on regression.
    static func groupFailure(_ mode: String) -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let files = FileService()
        let executable = root + "/group-git"
        let stdoutFailure = mode.contains("stdout")
        let partial = mode.hasSuffix("partial")
        var gitPID: pid_t = 0
        var helperPID: pid_t = 0
        var admitted = false
        do {
            try files.writeExecutableFile(at: executable, content: """
            #!/usr/bin/python3
            import os, signal, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            child = os.fork()
            if child == 0:
                os.close(\(stdoutFailure ? 1 : 2))
                with open('\(root)/children/' + str(os.getpid()), 'w') as f: f.write('helper')
                with open('\(root)/helper', 'w') as f:
                    if \(partial ? "True" : "False"):
                        while not os.path.exists('\(root)/helper.resume'): time.sleep(0.001)
                    f.write(str(os.getpid()))
            while True: time.sleep(1)
            """)
            let service = git(executable) { pid, descriptor, stdout, _ in
                guard stdout == stdoutFailure else { return }
                gitPID = pid
                helperPID = try readPID(at: root + "/helper") {
                    if partial { try files.writeFile(at: root + "/helper.resume", content: "publish") }
                }
                record(helperPID)
                admitted = getpgid(pid) == pid && getpgid(helperPID) == pid
                    && kill(pid, 0) == 0 && kill(helperPID, 0) == 0
                close(descriptor)
            }
            do {
                _ = try service.runData(["--version"], in: nil)
                return "FAIL missing read error"
            } catch GitError.outputReadFailed {
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while kill(helperPID, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                var status: Int32 = 0
                let reaped = waitpid(gitPID, &status, WNOHANG) == -1 && errno == ECHILD
                return admitted && reaped && kill(gitPID, 0) == -1 && kill(helperPID, 0) == -1
                    ? "OK read error; git and helper stopped; git reaped" : "FAIL group cleanup"
            }
        } catch { return "FAIL \(error)" }
    }
}
