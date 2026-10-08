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
        var buffer = [UInt8](repeating: 0, count: 16_384)
        do {
            let events = try GitOutputEvents(child: self)
            while true {
                let exited = try events.exitNotified || hasExited()
                if exited {
                    let outRemaining = try queuedBytes(stdout)
                    let errRemaining = try queuedBytes(stderr)
                    try read(stdout, maximum: outRemaining, into: &out, buffer: &buffer, exited: true)
                    try read(stderr, maximum: errRemaining, into: &err, buffer: &buffer, exited: true)
                    return try GitService.GitDataOutput(stdout: out, stderr: err, exit: reap())
                }
                if outOpen {
                    outOpen = try read(stdout, maximum: 65_536, into: &out, buffer: &buffer, exited: false)
                    if !outOpen { try events.removePipe(stdout) }
                }
                if errOpen {
                    errOpen = try read(stderr, maximum: 65_536, into: &err, buffer: &buffer, exited: false)
                    if !errOpen { try events.removePipe(stderr) }
                }
                // Pipe readiness and child exit both wake this caller, including exit after both EOFs.
                #if GIT_PROCESS_PROBE
                try probeHooks?.beforeWait?(pid, !outOpen && !errOpen)
                #endif
                try events.wait()
            }
        } catch {
            // Only the unreaped identity authorizes group cleanup. A failed reap may have consumed
            // the child already. Cleanup's own reap failure must not replace the local runner error.
            if ownsUnreapedChild {
                kill(-pid, SIGKILL)
                _ = try? reap()
            }
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
    private func read(_ descriptor: Int32, maximum: Int, into data: inout Data,
                      buffer: inout [UInt8], exited: Bool) throws -> Bool {
        #if GIT_PROCESS_PROBE
        try probeHooks?.beforeRead(pid, descriptor, descriptor == stdout, exited)
        #endif
        var remaining = maximum
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

/// Kernel notifications do not reap the child. Its identity remains owned until all reads succeed.
private final class GitOutputEvents {
    #if GIT_PROCESS_PROBE
    private let probeHooks: GitProcessProbeHooks?
    #endif
    private var queue: Int32
    private var ready = Array(repeating: kevent(), count: 3)
    private(set) var exitNotified = false

    init(child: GitProcess) throws {
        #if GIT_PROCESS_PROBE
        probeHooks = child.probeHooks
        #endif
        queue = kqueue()
        guard queue != -1 else { throw GitProcess.posixError() }
        do {
            guard fcntl(queue, F_SETFD, FD_CLOEXEC) != -1 else { throw GitProcess.posixError() }
            try change(ident: UInt(child.stdout), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD))
            try change(ident: UInt(child.stderr), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD))
            do {
                #if GIT_PROCESS_PROBE
                try probeHooks?.beforeExitWatch?(child.pid)
                #endif
                try change(ident: UInt(child.pid), filter: Int16(EVFILT_PROC),
                           flags: UInt16(EV_ADD | EV_ONESHOT), notes: UInt32(NOTE_EXIT))
            } catch {
                // ESRCH can precede a waitable exit. We still own this unreaped pid, so the child
                // is exiting; wait for that exit without relying on a watch or a fixed sleep.
                guard (error as NSError).code == Int(ESRCH) else { throw error }
                let exited = try child.hasExited()
                #if GIT_PROCESS_PROBE
                try probeHooks?.exitWatchFailed?(child.pid, error, exited)
                #endif
                if !exited { try child.waitForExit() }
                exitNotified = true
            }
        } catch {
            close(queue)
            queue = -1
            throw error
        }
    }

    deinit { if queue != -1 { close(queue) } }

    func removePipe(_ descriptor: Int32) throws {
        try change(ident: UInt(descriptor), filter: Int16(EVFILT_READ), flags: UInt16(EV_DELETE))
    }

    private func change(ident: UInt, filter: Int16, flags: UInt16, notes: UInt32 = 0) throws {
        var event = kevent(ident: ident, filter: filter, flags: flags, fflags: notes, data: 0, udata: nil)
        while kevent(queue, &event, 1, nil, 0, nil) == -1 {
            guard errno == EINTR else { throw GitProcess.posixError() }
        }
    }

    func wait() throws {
        let count = kernelWait()
        let failureCode = errno
        #if GIT_PROCESS_PROBE
        probeHooks?.waitReturned?(count)
        #endif
        if count == -1 {
            guard failureCode == EINTR else { throw GitProcess.posixError(failureCode) }
            return
        }
        for event in ready.prefix(Int(count)) {
            if event.flags & UInt16(EV_ERROR) != 0 { throw GitProcess.posixError(Int32(event.data)) }
            if event.filter == Int16(EVFILT_PROC), event.fflags & UInt32(NOTE_EXIT) != 0 { exitNotified = true }
        }
    }

    private func kernelWait() -> Int32 {
        #if GIT_PROCESS_PROBE
        if let code = probeHooks?.waitFailure?() { errno = code; return -1 }
        #endif
        return kevent(queue, nil, 0, &ready, Int32(ready.count), nil)
    }
}
