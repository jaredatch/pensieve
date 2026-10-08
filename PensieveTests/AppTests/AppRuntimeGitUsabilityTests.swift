import XCTest
@testable import Pensieve

@MainActor
final class AppRuntimeGitUsabilityTests: XCTestCase {
    func testLaunchProbesOffMainThreadAndReportsFix() async throws {
        for (index, state) in [GitUsability.usable, .licenseNotAccepted, .developerToolsMissing].enumerated() {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            let git = try fixture.broken(state)
            let runtime = try AppRuntime(defaults: isolatedDefaults("launch-\(index)"), paths: fixture.paths, gitUsabilityProbe: {
                XCTAssertFalse(Thread.isMainThread)
                return try git.probeUsability()
            })
            await runtime.bootstrapTask.value
            XCTAssertEqual(runtime.gitUsability, state)
            if state == .licenseNotAccepted {
                XCTAssertTrue(runtime.gitUsability?.message?.contains("sudo xcodebuild -license") == true)
            } else if state == .developerToolsMissing {
                XCTAssertTrue(runtime.gitUsability?.message?.contains("xcode-select --install") == true)
            } else {
                XCTAssertNil(runtime.gitUsability?.message)
            }
            if state != .usable { await assertFailedProbeKeepsUnusableConfiguration(state) }
        }
        try await assertFailedLaunchProbeReportsConfigurationError()
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        var failRead = false
        let runtime = try AppRuntime(defaults: isolatedDefaults("local-probe-read"), paths: fixture.paths, gitUsabilityProbe: {
            if failRead { throw GitError.outputReadFailed(detail: "probe EIO") }
            return .usable
        })
        await runtime.bootstrapTask.value
        failRead = true
        await runtime.refreshGitUsability()
        XCTAssertEqual(runtime.gitUsability, .usable, "A local read failure supplies no host evidence")
        XCTAssertEqual(runtime.syncModel.configurationError, "Pensieve couldn’t read git’s output: probe EIO")
        failRead = false
        await runtime.refreshGitUsability()
        XCTAssertEqual(runtime.gitUsability, .usable)
        XCTAssertNil(runtime.syncModel.configurationError)
    }

    private func assertFailedLaunchProbeReportsConfigurationError() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let runtime = try AppRuntime(defaults: isolatedDefaults("launch-probe-read"), paths: fixture.paths,
                                     gitUsabilityProbe: { throw GitError.outputReadFailed(detail: "launch EIO") })
        await runtime.bootstrapTask.value
        XCTAssertNil(runtime.gitUsability, "A failed launch probe supplies no host evidence")
        XCTAssertEqual(runtime.syncModel.configurationError, "Pensieve couldn’t read git’s output: launch EIO")
        XCTAssertEqual(runtime.syncModel.configurationDescription, "Pensieve couldn’t read git’s output: launch EIO")
        XCTAssertFalse(runtime.syncModel.canConnect)
    }

    private func assertFailedProbeKeepsUnusableConfiguration(_ unusable: GitUsability) async {
        let git = IngestRecordingGit()
        let readLock = NSLock()
        var reads = 0
        git.remoteRead = { readLock.withLock { reads += 1 }; return nil }
        let model = SyncModel(git: git, root: "/unused-test-root")
        let state = RuntimeGitState(probe: { throw GitError.outputReadFailed(detail: "probe EIO") })
        model.observeGitState(state)
        model.applyConfiguration(.success(.init(remoteURL: nil, hasLocalBranches: true)), order: model.beginConfiguration())
        _ = state.accept(unusable, order: state.beginEvidence(), model: model)
        _ = await state.refresh(probingGit: true, model: model)
        XCTAssertEqual(state.usability, unusable)
        XCTAssertEqual(readLock.withLock { reads }, 0, "Unusable git gates configuration reads")
        // Fresh git evidence exposes the cached configuration answer before another remote read.
        _ = state.accept(.usable, order: state.beginEvidence(), model: model)
        XCTAssertNil(model.configurationError, "The failed probe must not replace the known absent answer")
        XCTAssertTrue(model.canConnect)
    }
}
