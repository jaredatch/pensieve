import Darwin
import Foundation

extension GitProcessProbe {
    static func holder(_ mode: String) -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let files = FileService()
        let executable = root + "/holder-git"
        let pipe = mode.contains("stdout") ? 1 : 2
        let writing = mode.contains("writing")
        let afterExit = mode == "holder-after-exit-failure"
        do {
            try files.writeExecutableFile(at: executable, content: """
            #!/usr/bin/python3
            import os, time
            child = os.fork()
            if child == 0:
                os.setsid()
                os.close(\(pipe == 1 ? 2 : 1))
                with open('\(root)/children/' + str(os.getpid()), 'w') as f: f.write('holder')
                with open('\(root)/holder', 'w') as f: f.write(str(os.getpid()))
                while True:
                    if \(writing ? "True" : "False"):
                        try: os.write(\(pipe), b'H' * 4096)
                        except BrokenPipeError: pass
                    time.sleep(0.001 if \(writing ? "True" : "False") else 1)
            while not os.path.exists('\(root)/holder'): time.sleep(0.001)
            os.write(1, b'O' * \(afterExit ? 128 : 262144))
            os.write(2, b'E' * \(afterExit ? 128 : 262144))
            os._exit(23)
            """)
            var failedAfterExit = false
            let service = git(executable, started: { pid in
                if afterExit { waitForUnreapedExit(pid) }
            }, beforeRead: { _, descriptor, stdout, exited in
                if afterExit, stdout, exited {
                    failedAfterExit = true
                    close(descriptor)
                }
            })
            let output: GitService.GitDataOutput
            do { output = try service.runData(["--version"], in: nil) } catch GitError.outputReadFailed {
                let pid = pid_t(try files.readFile(at: root + "/holder")) ?? 0
                return failedAfterExit && pid > 0 && kill(pid, 0) == 0
                    ? "OK read error after exit; holder alive" : "FAIL exit fault"
            }
            let pid = pid_t(try files.readFile(at: root + "/holder")) ?? 0
            let alive = pid > 0 && kill(pid, 0) == 0
            // The holder may interleave H bytes; remove only those independently known fixture bytes.
            let intact = Data(output.stdout.filter { $0 != 72 }) == Data(repeating: 79, count: 262_144)
                && Data(output.stderr.filter { $0 != 72 }) == Data(repeating: 69, count: 262_144)
            return alive && intact && output.exit == 23
                ? "OK output, status; holder alive" : "FAIL alive=\(alive), intact=\(intact)"
        } catch { return "FAIL \(error)" }
    }

    private static func waitForUnreapedExit(_ pid: pid_t) {
        var info = siginfo_t()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while info.si_pid != pid && ProcessInfo.processInfo.systemUptime < deadline {
            _ = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
