import Darwin
import Foundation

extension GitProcessProbe {
    /// Consume a real child's status, then fail the owner's reap. Its surviving group member
    /// must remain alive on the exit path; a read-failure path has already killed that group.
    static func reapFailure(_ mode: String) -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let files = FileService()
        let executable = root + "/reap-git"
        let readFailure = mode == "reap-cleanup-failure"
        do {
            try files.writeExecutableFile(at: executable, content: """
            #!/usr/bin/python3
            import os, time
            child = os.fork()
            if child == 0:
                with open('\(root)/children/' + str(os.getpid()), 'w') as f: f.write('helper')
                with open('\(root)/helper', 'w') as f: f.write(str(os.getpid()))
                while not os.path.exists('\(root)/check'): time.sleep(0.0001)
                with open('\(root)/alive', 'w') as f: f.write('alive')
                while True: time.sleep(1)
            while not os.path.exists('\(root)/exit'): time.sleep(0.0001)
            os.write(1, b'O' * 128)
            os.write(2, b'E' * 128)
            os._exit(23)
            """)
            var helper: pid_t = 0
            var attempts = 0
            var consumed = false
            let service = git(executable, hooks: { hooks in
                hooks.beforeReap = { pid in
                    attempts += 1
                    var status: Int32 = 0
                    consumed = waitpid(pid, &status, 0) == pid
                    throw GitProcess.posixError(EIO)
                }
            }, beforeRead: { pid, descriptor, stdout, _ in
                guard stdout, helper == 0 else { return }
                helper = try readPID(at: root + "/helper")
                guard getpgid(helper) == pid else { throw GitProcess.posixError(EINVAL) }
                if readFailure { close(descriptor) } else {
                    try files.writeFile(at: root + "/exit", content: "exit")
                    try waitForUnreapedExit(pid)
                }
            })
            do {
                _ = try service.runData(["--version"], in: nil)
                return "FAIL missing reap error"
            } catch GitError.outputReadFailed {
                guard consumed, attempts == 1 else { return "FAIL reap attempts=\(attempts), consumed=\(consumed)" }
                if readFailure { return "OK cleanup reap error stays local" }
                return try survivingHelper(helper, root: root, files: files)
                    ? "OK reap error; group helper alive" : "FAIL signalled group after failed reap"
            } catch { return "FAIL raw reap error: \(error); attempts=\(attempts)" }
        } catch { return "FAIL reap fixture: \(error)" }
    }

    private static func survivingHelper(_ pid: pid_t, root: String, files: FileService) throws -> Bool {
        try files.writeFile(at: root + "/check", content: "check")
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !files.fileExists(at: root + "/alive"), ProcessInfo.processInfo.systemUptime < deadline { usleep(100) }
        return files.fileExists(at: root + "/alive") && kill(pid, 0) == 0
    }
}
