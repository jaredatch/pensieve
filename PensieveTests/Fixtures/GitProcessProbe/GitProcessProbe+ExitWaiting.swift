import Darwin
import Foundation

extension GitProcessProbe {
    /// Force EOF before exit, and exit during the last read. Measure from waitid's exit observation,
    /// independently of the runner. A median admits isolated scheduling delays, not a fixed idle wait.
    static func exitLatency() -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let files = FileService()
        var latencies: [TimeInterval] = []
        do {
            for index in 0..<7 {
                let base = root + "/exit-\(index)"
                let executable = base + "-git"
                try files.writeExecutableFile(at: executable, content: """
                #!/usr/bin/python3
                import os, time
                os.close(1)
                os.close(2)
                with open('\(base).ready', 'w') as f: f.write('ready')
                while not os.path.exists('\(base).exit'): time.sleep(0.0001)
                os._exit(23)
                """)
                var observedExit: TimeInterval?
                let service = git(executable, beforeRead: { pid, _, stdout, exited in
                    guard !exited, observedExit == nil else { return }
                    let deadline = ProcessInfo.processInfo.systemUptime + 5
                    if stdout {
                        while !files.fileExists(at: base + ".ready"), ProcessInfo.processInfo.systemUptime < deadline {
                            usleep(100)
                        }
                        guard files.fileExists(at: base + ".ready") else { throw GitProcess.posixError(ETIMEDOUT) }
                    } else {
                        try files.writeFile(at: base + ".exit", content: "exit")
                        observedExit = try observeExit(pid, before: deadline)
                    }
                })
                let output = try service.runData(["--version"], in: nil)
                let returned = ProcessInfo.processInfo.systemUptime
                guard let observedExit, output.exit == 23, output.stdout.isEmpty, output.stderr.isEmpty else {
                    return "FAIL EOF/exit admission or output"
                }
                latencies.append(returned - observedExit)
            }
            let median = latencies.sorted()[latencies.count / 2]
            // upper-bound: Detect the old 10 ms sleep after both descriptors reach EOF.
            return median < 0.008 ? "OK exit wake; empty output, status" : "FAIL exit-to-return median=\(median)s"
        } catch { return "FAIL \(error)" }
    }

    private static func observeExit(_ pid: pid_t, before deadline: TimeInterval) throws -> TimeInterval {
        var info = siginfo_t()
        repeat {
            guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
                throw GitProcess.posixError()
            }
            if info.si_pid != pid { usleep(100) }
        } while info.si_pid != pid && ProcessInfo.processInfo.systemUptime < deadline
        guard info.si_pid == pid else { throw GitProcess.posixError(ETIMEDOUT) }
        return ProcessInfo.processInfo.systemUptime
    }
}
