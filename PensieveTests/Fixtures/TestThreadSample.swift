import Darwin
import Foundation
@testable import Pensieve

/// Failure-only diagnostics. A dedicated Foundation thread spawns and reaps sample with POSIX
/// calls. The child writes directly to a file: neither scheduling nor output depends on GCD,
/// Swift concurrency, Foundation Process notifications, or pipe draining. Partial files survive
/// the deadline; launch/read failures are evidence rather than additional XCTest failures.
enum TestThreadSample {
    private final class Completion {
        let condition = NSCondition()
        var result: String?
    }

    static func capture(
        executable: String = "/usr/bin/sample",
        timeout: TimeInterval = 45,
        beforeDeadline: @escaping (pid_t, String) -> Void = { _, _ in }
    ) -> String {
        let census = TestThreadCensus.capture()
        let completion = Completion()
        Thread.detachNewThread {
            Thread.current.name = "Pensieve timeout sampler"
            let result = captureOnThread(executable: executable, timeout: timeout, beforeDeadline: beforeDeadline)
            completion.condition.lock()
            completion.result = result
            completion.condition.signal()
            completion.condition.unlock()
        }
        completion.condition.lock()
        defer { completion.condition.unlock() }
        while completion.result == nil { completion.condition.wait() }
        return census + "\n" + (completion.result ?? "Sampler did not return a report")
    }

    private static func captureOnThread(
        executable: String, timeout: TimeInterval, beforeDeadline: (pid_t, String) -> Void
    ) -> String {
        let files = FileService()
        let directory = TestTemporaryDirectory.path + "PensieveThreadSample-" + UUID().uuidString
        do { try files.createDirectory(at: directory) } catch { return "Sampler directory failed: \(error)" }
        defer { try? files.deleteDirectory(at: directory) }
        let path = directory + "/threads.txt"
        let arguments = [executable, String(getpid()), "2", "-mayDie", "-file", path]
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        var pid: pid_t = 0
        let launched = spawn(&pid, executable: executable, argv: &argv)
        guard launched == 0 else { return "Could not launch sampler: errno=\(launched)" }
        // Test seam: a fake sampler can publish readiness before its short deadline starts.
        // Real captures use the no-op default and start their deadline immediately after spawn.
        beforeDeadline(pid, path)
        let status = reap(pid, timeout: timeout)
        let report: String
        do { report = try files.readFile(at: path) } catch { report = "Sampler report unavailable: \(error)" }
        return "sampler pid=\(pid); \(status)\n\(report)"
    }

    private static func spawn(_ pid: inout pid_t, executable: String, argv: inout [UnsafeMutablePointer<CChar>?]) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        let initialized = posix_spawn_file_actions_init(&actions)
        guard initialized == 0 else { return initialized }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // sample's progress messages must not depend on XCTest's stdout transport either.
        let redirected = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        guard redirected == 0 else { return redirected }
        let duplicated = posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        guard duplicated == 0 else { return duplicated }
        return posix_spawn(&pid, executable, &actions, nil, &argv, environ)
    }

    private static func reap(_ pid: pid_t, timeout: TimeInterval) -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return "sampler wait status=\(status)" }
            if result < 0 && errno != EINTR { return "sampler waitpid failed: errno=\(errno)" }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(10_000)
        }
        kill(pid, SIGKILL)
        // Reap our child directly, without a termination callback queued on an exhausted pool.
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return "sampler kill/reap failed: errno=\(errno)" }
        }
        return "sampler exceeded \(timeout)-second bound; killed and reaped; wait status=\(status)"
    }
}
