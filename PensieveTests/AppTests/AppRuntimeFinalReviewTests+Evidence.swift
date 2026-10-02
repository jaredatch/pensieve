import SwiftData
import XCTest
@testable import Pensieve

extension AppRuntimeFinalReviewTests {
    func testUnconfirmedHintUsesDiagnosticProbeBeforeChangingUsability() async throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        for (index, answer) in [GitUsability.usable, .licenseNotAccepted].enumerated() {
            let reads = RuleProbe()
            let git = IngestRecordingGit()
            git.remoteRead = { _ = reads.run(); return "https://fixture.test/store.git" }
            let probe = RuleProbe()
            probe.set { .developerToolsMissing }
            let bypass = GitService(upstreamHistoryNetworkRunner: { _, _ in
                .init(stdout: "", stderr: "xcrun: error: invalid active developer path", exit: 69)
            })
            let runtime = try AppRuntime(syncModel: SyncModel(git: git, root: fixture.root),
                scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
                defaults: isolatedDefaults("evidence-\(index)"), paths: fixture.paths, updateCheckOperation: { _ in
                    _ = try bypass.remoteHead(remote: "https://fixture.test/store.git", ref: "main", credential: nil)
                    return RuntimeUpdateCheckResult(report: UpdateCheckReport(), skills: [:])
                }, gitUsabilityProbe: probe.run)
            await runtime.bootstrapTask.value
            let before = reads.count
            probe.set { answer }
            runtime.checkForSkillUpdatesNow()
            await TestWait.until(failureMessage: "check did not finish") { !runtime.updateCheckInFlight }
            XCTAssertEqual(runtime.gitUsability, answer, "only the diagnostic answer changes usability")
            XCTAssertEqual(reads.count, before + (answer == .usable ? 1 : 0))
            XCTAssertEqual(probe.count, 2, "an unconfirmed injected hint requires a diagnostic probe")
            let failure = GitError.commandFailed(args: ["clone"], exitCode: 69, stderr: "Xcode license not accepted")
            XCTAssertNil(ClassifiedUpdateFailure.classify(failure).usability)
        }
    }
}
