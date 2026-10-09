import XCTest
@testable import Pensieve

extension AppRuntimeSyncRecoveryTests {
    func assertConcurrentProbeCannotSuppressStartupFailure() async throws {
        let started = expectation(description: "startup probe entered")
        let release = TestWait.Gate(owner: self)
        let probe = RuleProbe()
        probe.set {
            if probe.count == 1 {
                started.fulfill()
                try? release.wait()
            }
            return .usable
        }
        let startup = Task {
            try await makeSyncRecoveryHarness(probe: probe,
                initialProbeError: GitError.outputReadFailed(detail: "bootstrap EIO"))
        }
        await fulfillment(of: [started], timeout: TestWait.hostedActionTimeoutSeconds)
        await TestWait.until(failureMessage: "startup probe did not block") { release.waiterCount == 1 }
        let concurrent = await BlockingWork.run(priority: .utility) { probe.run() }
        XCTAssertEqual(concurrent, .usable)
        XCTAssertEqual(probe.count, 2, "the other call must finish before startup resumes")
        release.open()
        let h = try await startup.value
        XCTAssertNil(h.runtime.gitUsability, "startup keeps its own failure despite the later shared count")
        XCTAssertEqual(h.runtime.syncModel.configurationError, "Pensieve couldn’t read git’s output: bootstrap EIO")
        await h.finish()
    }
}
