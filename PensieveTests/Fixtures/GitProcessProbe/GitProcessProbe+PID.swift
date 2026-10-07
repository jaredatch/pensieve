import Darwin
import Foundation

extension GitProcessProbe {
    /// File creation precedes buffered publication. Wait for a complete, positive identity.
    static func readPID(at path: String, onIncomplete: () throws -> Void = {}) throws -> pid_t {
        let files = FileService()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if files.fileExists(at: path) {
                if let pid = pid_t(try files.readFile(at: path)), pid > 0 { return pid }
                try onIncomplete()
            }
            usleep(1_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw GitProcess.posixError(ETIMEDOUT)
    }
}
