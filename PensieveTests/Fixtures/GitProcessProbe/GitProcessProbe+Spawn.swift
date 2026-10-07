import Darwin
import Foundation

extension GitProcessProbe {
    /// A C main observes the exec contract before a shell or interpreter installs its own handlers.
    static func spawnSignals() -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let source = root + "/signals.c"
        let executable = root + "/signals-git"
        do {
            try FileService().writeFile(at: source, content: """
            #include <signal.h>
            #include <stdio.h>
            int main(void) {
                sigset_t mask;
                sigprocmask(SIG_BLOCK, NULL, &mask);
                int blocked = 0, nondefault = 0;
                for (int s = 1; s < NSIG; s++) {
                    if (sigismember(&mask, s) == 1) blocked++;
                    struct sigaction action;
                    if (sigaction(s, NULL, &action) == 0 && action.sa_handler != SIG_DFL) nondefault++;
                }
                printf("blocked=%d nondefault=%d", blocked, nondefault);
                return blocked || nondefault;
            }
            """)
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            compiler.arguments = [source, "-o", executable]
            try compiler.run()
            record(compiler.processIdentifier)
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else { return "FAIL fixture compilation" }
            // Dispositions are process-wide. This disposable probe changes them, never the test host.
            for value in [SIGPIPE, SIGALRM, SIGTERM, SIGINT] { signal(value, SIG_IGN) }
            let done = DispatchGroup()
            var result = "FAIL caller did not run"
            done.enter()
            let caller = Thread {
                defer { done.leave() }
                var mask = sigset_t()
                sigfillset(&mask)
                guard pthread_sigmask(SIG_SETMASK, &mask, nil) == 0 else { return }
                var actual = sigset_t()
                pthread_sigmask(SIG_BLOCK, nil, &actual)
                guard sigismember(&actual, SIGTERM) == 1, sigismember(&actual, SIGCHLD) == 1 else { return }
                do {
                    let output = try git(executable).runData(["--version"], in: nil)
                    let text = String(bytes: output.stdout, encoding: .utf8) ?? ""
                    result = output.exit == 0 && text == "blocked=0 nondefault=0"
                        ? "OK child signals; blocked caller" : "FAIL child \(text)"
                } catch { result = "FAIL \(error)" }
            }
            caller.start()
            done.wait()
            return result
        } catch { return "FAIL \(error)" }
    }

    static func usabilityRead(_ mode: String) -> String {
        let root = (CommandLine.arguments[3] as NSString).deletingLastPathComponent
        let executable = root + "/usability-git"
        var launches = 0
        var child: pid_t = 0
        do {
            try FileService().writeExecutableFile(at: executable, content: """
            #!/bin/sh
            if [ "$1" = --version ]; then exec /bin/sleep 60; fi
            echo 'xcrun: error: invalid active developer path' >&2
            exit 1
            """)
            let service = git(executable, started: { pid in launches += 1; child = pid },
                              beforeRead: { _, descriptor, stdout, _ in
                if stdout, launches == (mode == "confirmation-read" ? 2 : 1) { close(descriptor) }
            })
            do {
                if mode == "confirmation-read" { _ = try service.runData(["status"], in: nil) } else {
                    try service.probeUsability().requireUsable()
                }
                return "FAIL missing probe read error"
            } catch GitError.outputReadFailed {
                var status: Int32 = 0
                let reaped = waitpid(child, &status, WNOHANG) == -1 && errno == ECHILD
                return reaped && kill(child, 0) == -1 ? "OK probe read error; child reaped" : "FAIL probe cleanup"
            } catch { return "FAIL wrong probe error: \(error)" }
        } catch { return "FAIL \(error)" }
    }
}
