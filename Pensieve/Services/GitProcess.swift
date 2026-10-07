import Darwin
import Foundation

/// Owns an unreaped child identity and its process group. Only this owner waits or signals it.
/// Subprocess descriptors are part of GitService's sanctioned filesystem-boundary exception.
final class GitProcess {
    let pid: pid_t
    let stdout: Int32
    let stderr: Int32
    #if GIT_PROCESS_PROBE
    var probeHooks: GitProcessProbeHooks?
    #endif

    init(executable: String, arguments: [String], workingDirectory: String?, environment: [String: String]) throws {
        let out = try Self.makePipe()
        defer { close(out.write) }
        let err: (read: Int32, write: Int32)
        do { err = try Self.makePipe() } catch { close(out.read); throw error }
        defer { close(err.write) }
        do {
            pid = try Self.spawn(executable, arguments: arguments, workingDirectory: workingDirectory,
                                 environment: environment, stdout: out.write, stderr: err.write)
        } catch {
            close(out.read)
            close(err.read)
            throw error
        }
        stdout = out.read
        stderr = err.read
    }

    /// CLOEXEC prevents another concurrent spawn inheriting our pipe ends and holding EOF open.
    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw posixError() }
        do {
            for index in descriptors.indices where descriptors[index] < 3 {
                let replacement = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                guard replacement != -1 else { throw posixError() }
                close(descriptors[index])
                descriptors[index] = replacement
            }
            for descriptor in descriptors {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else { throw posixError() }
            }
            guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) != -1 else { throw posixError() }
            return (descriptors[0], descriptors[1])
        } catch {
            descriptors.forEach { close($0) }
            throw error
        }
    }

    private static func spawn(
        _ executable: String, arguments: [String], workingDirectory: String?,
        environment: [String: String], stdout: Int32, stderr: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try requireZero(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try requireZero(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // A new group is established atomically in the child, before executable code runs.
        try requireZero(posix_spawnattr_setpgroup(&attributes, 0))
        try requireZero(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try requireZero(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try requireZero(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
        try requireZero(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
        try requireZero(posix_spawn_file_actions_addclose(&actions, stdout))
        try requireZero(posix_spawn_file_actions_addclose(&actions, stderr))
        if let workingDirectory {
            try requireZero(posix_spawn_file_actions_addchdir(&actions, workingDirectory))
        }
        let argv = ([executable] + arguments).map { strdup($0) }
        let env = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + env).forEach { free($0) } }
        var child: pid_t = 0
        try (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
            try (env + [nil]).withUnsafeBufferPointer { envBuffer in
                try requireZero(posix_spawn(&child, executable, &actions, &attributes,
                                           argvBuffer.baseAddress, envBuffer.baseAddress))
            }
        }
        return child
    }

    static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func requireZero(_ code: Int32) throws {
        guard code == 0 else { throw posixError(code) }
    }

    /// Observe without reaping: the pid cannot be recycled before group-failure cleanup.
    func hasExited() throws -> Bool {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            guard errno == EINTR else { throw Self.posixError() }
        }
        return info.si_pid == pid
    }

    func reap() throws -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw Self.posixError() }
        }
        // waitpid's status encodes a normal exit in the high byte, or a signal in the low seven bits.
        return status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
    }
}
