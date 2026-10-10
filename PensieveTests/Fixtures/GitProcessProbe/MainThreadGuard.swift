import Darwin
import Foundation

extension GitProcessProbe {
    static func expectedCaller(_ report: String, line: UInt, file: StaticString = #fileID) {
        do { try FileService().writeFile(at: report, content: "\(file):\(line)") } catch { exit(74) }
    }

    static func mainThreadGuard(_ mode: String, executable: String, report: String) {
        let service = git(executable)
        if mode.hasPrefix("main-thread-store-") {
            storeGuard(mode, service: service, report: report)
        } else if mode.hasPrefix("main-thread-daemon-") {
            daemonGuard(mode, service: service, report: report)
        } else if mode == "main-thread-public" {
            publicGuard(service, report: report)
        } else if mode == "main-thread-closure" {
            expectedCaller(report, line: #line + 1)
            _ = try? service.runBestEffort(["--version"], in: nil)
        } else {
            expectedCaller(report, line: #line + 1)
            _ = try? service.runData(["--version"], in: nil)
        }
    }

    static func publicGuard(_ service: GitServiceProtocol, report: String) {
        expectedCaller(report, line: #line + 1)
        _ = try? service.probeUsability()
    }

    static func daemonGuard(_ mode: String, service: FastForwardGitService, report: String) {
        switch mode {
        case "main-thread-daemon-fetch":
            expectedCaller(report, line: #line + 1)
            try? service.fetch(at: "/unused", credential: nil)
        case "main-thread-daemon-forward":
            expectedCaller(report, line: #line + 1)
            _ = try? service.fastForwardOnly(at: "/unused", credential: nil)
        default:
            expectedCaller(report, line: #line + 1)
            _ = try? service.remoteURL(at: "/unused")
        }
    }

    static func storeGuard(_ mode: String, service: GitService, report: String) {
        // Prepare the real operation off main without registering its already-reaped setup children.
        let ready = DispatchSemaphore(value: 0)
        var operation: StoreGitOperation?
        let root = (report as NSString).deletingLastPathComponent + "/repository"
        Thread {
            let setup = GitService(askpassHelperPath: root + "/askpass")
            try? FileService().createDirectory(at: root)
            try? setup.initRepository(at: root)
            operation = try? service.storeOperation(at: root)
            ready.signal()
        }.start()
        ready.wait()
        guard let operation else { exit(74) }
        // The operation's setup used the probe service; discard only those completed children.
        let registry = (report as NSString).deletingLastPathComponent + "/children"
        for child in (try? FileService().listDirectory(at: registry)) ?? [] {
            try? FileService().deleteFile(at: registry + "/" + child)
        }
        switch mode {
        case "main-thread-store-run":
            expectedCaller(report, line: #line + 1)
            _ = try? operation.run(["status", "--porcelain"])
        case "main-thread-store-throw":
            expectedCaller(report, line: #line + 1)
            _ = try? operation.runOrThrow(["status", "--porcelain"])
        default:
            expectedCaller(report, line: #line + 1)
            _ = try? operation.runData(["status", "--porcelain"])
        }
    }
}
