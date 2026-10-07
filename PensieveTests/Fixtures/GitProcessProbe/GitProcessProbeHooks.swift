import Darwin

/// Compiled only into the disposable probe. Faults and child registration cannot reach the app or
/// daemon: those targets compile neither this type nor the GIT_PROCESS_PROBE branches in the runner.
struct GitProcessProbeHooks {
    typealias BeforeRead = (pid_t, Int32, Bool, Bool) throws -> Void
    typealias ExitWatchFailed = (pid_t, Error, Bool) throws -> Void
    let started: (pid_t) -> Void
    let beforeRead: BeforeRead
    var beforeExitWatch: ((pid_t) throws -> Void)?
    var exitWatchFailed: ExitWatchFailed?
}
