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
        }
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
}
