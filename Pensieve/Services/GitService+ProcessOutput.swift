import Darwin
import Foundation

extension GitService {
    /// Internal transport seam for fault and scheduling tests. Normal calls own fresh pipes and a child.
    struct ProcessIO {
        var process = Process()
        var stdout = Pipe()
        var stderr = Pipe()
        var read: (FileHandle) throws -> Data? = { try $0.readToEnd() }
    }

    func readOutput(_ io: ProcessIO, args: [String]) throws -> (Data, Data) {
        // Drain both pipes concurrently, without queued GCD work. A read failure on either
        // side stops the child immediately so the other reader can reach EOF and join.
        let cleanup = ReadFailureCleanup(io.process)
        let drain = PipeDrain(io.stderr.fileHandleForReading, read: io.read, onFailure: cleanup.stop)
        let stdout = Result { try io.read(io.stdout.fileHandleForReading) ?? Data() }
        if case .failure = stdout { cleanup.stop() }
        let stderr = drain.join()
        io.process.waitUntilExit()
        do { return (try stdout.get(), try stderr.get()) } catch {
            throw GitError.commandFailed(args: args, exitCode: io.process.terminationStatus,
                                         stderr: "Could not read git output: \(error.localizedDescription)")
        }
    }

    /// Internal pipe transport cleanup shared with tests; it performs no file reads.
    final class ReadFailureCleanup {
        private let process: Process
        private let lock = NSLock()
        private var stopped = false

        init(_ process: Process) { self.process = process }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, process.isRunning else { return }
            stopped = true
            // An I/O failure cannot be recovered by waiting for more output. SIGKILL also
            // bounds cleanup for a child that ignores SIGTERM. Descendants are out of scope.
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Internal reader for pipe handles only. File reads stay behind FileService.
    final class PipeDrain {
        private let condition = NSCondition()
        private var result: Result<Data, Error>?

        init(_ handle: FileHandle, read: @escaping (FileHandle) throws -> Data?, onFailure: @escaping () -> Void) {
            let thread = Thread {
                let result = Result { try read(handle) ?? Data() }
                if case .failure = result { onFailure() }
                self.condition.lock()
                self.result = result
                self.condition.signal()
                self.condition.unlock()
            }
            thread.name = "Pensieve git stderr drain"
            thread.qualityOfService = Thread.current.qualityOfService
            thread.start()
        }

        func join() -> Result<Data, Error> {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let result { return result }
                condition.wait()
            }
        }
    }
}
