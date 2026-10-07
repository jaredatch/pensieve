import Darwin
import Foundation

extension GitProcess {
    /// Read both nonblocking pipes on the caller, checking child exit between bounded reads.
    /// At exit, capture each pipe's queued-byte count before reading either final tail. A descendant
    /// can keep writing, but cannot enlarge these budgets. Bytes git wrote before exit are included.
    func readOutput() throws -> GitService.GitDataOutput {
        defer { close(stdout); close(stderr) }
        var out = Data()
        var err = Data()
        var outOpen = true
        var errOpen = true
        do {
            while true {
                let exited = try hasExited()
                if exited {
                    let outRemaining = try queuedBytes(stdout)
                    let errRemaining = try queuedBytes(stderr)
                    try read(stdout, maximum: outRemaining, into: &out, exited: true)
                    try read(stderr, maximum: errRemaining, into: &err, exited: true)
                    return try GitService.GitDataOutput(stdout: out, stderr: err, exit: reap())
                }
                if outOpen { outOpen = try read(stdout, maximum: 65_536, into: &out, exited: false) }
                if errOpen { errOpen = try read(stderr, maximum: 65_536, into: &err, exited: false) }
                var descriptors = [pollfd(fd: outOpen ? stdout : -1, events: Int16(POLLIN), revents: 0),
                                   pollfd(fd: errOpen ? stderr : -1, events: Int16(POLLIN), revents: 0)]
                // EOF can precede child exit. Even with no open pipe, observe git's life at this interval.
                if poll(&descriptors, nfds_t(descriptors.count), 10) == -1, errno != EINTR {
                    throw Self.posixError()
                }
            }
        } catch {
            // This child remains unreaped even if exit was already observed. Its group cannot belong
            // to a recycled pid. SIGKILL bounds cleanup when a helper ignores SIGTERM or holds a pipe.
            kill(-pid, SIGKILL)
            _ = try reap()
            throw GitError.outputReadFailed(detail: error.localizedDescription)
        }
    }

    private func queuedBytes(_ descriptor: Int32) throws -> Int {
        var count: Int32 = 0
        // Darwin's FIONREAD = _IOR('f', 127, int). Swift cannot import the function-like macro expansion.
        let request: UInt = 0x4004667f
        guard ioctl(descriptor, request, &count) == 0 else { throw Self.posixError() }
        return Int(count)
    }

    @discardableResult
    private func read(_ descriptor: Int32, maximum: Int, into data: inout Data, exited: Bool) throws -> Bool {
        #if GIT_PROCESS_PROBE
        try probeHooks?.beforeRead(pid, descriptor, descriptor == stdout, exited)
        #endif
        var remaining = maximum
        var buffer = [UInt8](repeating: 0, count: min(16_384, max(1, maximum)))
        while remaining > 0 {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                remaining -= count
            } else if count == 0 {
                return false
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return true
            } else {
                throw Self.posixError()
            }
        }
        return true
    }
}
