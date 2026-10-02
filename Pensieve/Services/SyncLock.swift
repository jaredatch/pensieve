import Foundation

/// A cross-process advisory lock guarding all git + manifest mutation of `~/.pensieve` (PLAN-12 / 12.5).
///
/// The background sync daemon and a running GUI both operate on `~/.pensieve/.git`; two `git` processes
/// mutating one repo concurrently corrupts it. Every repo-mutating flow — the daemon's `runOnce` (Stage 12.6)
/// and the three GUI git entry points (`SyncEngine.sync`/`inspectConflicts`/`resolveConflicts` and the
/// `SyncSetupModel` setup sequence) — calls `tryAcquire()` before any git call and holds the returned lock
/// for the whole flow. A non-blocking BSD `flock(2)` (`LOCK_EX | LOCK_NB`): the FIRST holder wins; a second
/// acquirer (in this process or another) gets `nil` and short-circuits — the daemon to `skipped(.locked)`,
/// the GUI to "sync already running." The kernel releases the lock on `close(2)` and on process death, so a
/// crashed holder never wedges the store (no manual cleanup, no stale PID files).
///
/// Reference type (not the plan sketch's `struct`) so the owned file descriptor has single, well-defined
/// ownership: `release()` is idempotent and a `deinit` safety net closes a lock the caller forgot to release,
/// which a copyable value type could double-close (closing an unrelated, reused fd). SwiftData-free — the
/// daemon target compiles it. Uses raw POSIX + `FileManager.createDirectory` rather than `FileService`: this
/// is a leaf OS-lock primitive with a static, zero-dependency API — `FileService` intentionally models
/// skill-tree CRUD, not file descriptors or advisory locks (Decision Log 12.5).
final class SyncLock {
    private var fd: Int32
    private var released = false

    private init(fd: Int32) { self.fd = fd }

    /// Non-blocking acquire. Returns a held lock, or `nil` if another holder has it. Fail-safe: also `nil`
    /// if the lock file cannot be opened — never proceed with git under an unestablished lock.
    static func tryAcquire(
        at path: String = PathConstants.pensieveAppSupportDir + "/sync.lock"
    ) -> SyncLock? {
        // Ensure the containing dir exists (fresh install): a missing parent would fail `open`. The askpass
        // helper also lives here but is written lazily by a later git op, so the lock must not rely on it.
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // O_CLOEXEC: git child processes we spawn must NOT inherit (and thus co-hold) this lock fd.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }                 // can't establish the lock → fail safe (busy)

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)                                     // held by someone else (EWOULDBLOCK) → not ours
            return nil
        }
        return SyncLock(fd: fd)
    }

    /// Blocking leaf-lock acquire. This is ONLY for tiny leaf critical sections such as
    /// `deploy-state.lock`: callers must not acquire other locks, run git, or perform canonical-store I/O
    /// while holding it. The whole-cycle `sync.lock` stays non-blocking via `tryAcquire()` so the GUI never
    /// beachballs behind a daemon fetch.
    static func acquire(at path: String) -> SyncLock? {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }

        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            return nil
        }
        return SyncLock(fd: fd)
    }

    /// Release the lock and close the descriptor. Idempotent — safe to call more than once.
    func release() {
        guard !released else { return }
        released = true
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
