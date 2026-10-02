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
                return git.probeUsability()
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
    }
}
