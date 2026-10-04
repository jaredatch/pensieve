import SwiftData
import XCTest
@testable import Pensieve

extension PostSyncConvergenceTests {
    func testLaunchAndHeadAdvanceRealizeUserWideAndProjectIntentWithoutLegacyEffects() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("intent")
        let legacyOnly = try harness.insertSkill("legacy-only")
        let project = try harness.insertProject(name: "Project", path: "/projects/intent", key: "key")
        let legacy = Scenario(name: "Retired")
        legacy.skillSlugs = [legacyOnly.directoryName]
        legacy.agentRawValues = ["codex"]
        harness.context.insert(legacy)
        let userIntent = try harness.insertIntent(skill: skill, platformRaw: "codex")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "key")
        let recorder = ConvergenceRecorder()
        let intent = IntentReconciler(
            platformVM: harness.platformVM,
            machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
            handoverIsComplete: { true }
        )
        let convergence = PostSyncConvergence(
            root: "/unused",
            deployReconciler: ConvergenceRecordingDeploy(recorder: recorder),
            contextFactory: { harness.context },
            categoryReconciler: CategoryReconciler(platformVM: harness.platformVM),
            intentReconciler: intent,
            auditLog: { _, detail in recorder.events.append(detail) }
        )

        convergence.runAfterLaunchIngest()
        XCTAssertEqual(harness.linkService.linkCalls, [
            DeployRecordedLink(directoryName: "intent", platform: .codex, projectPath: nil),
            DeployRecordedLink(directoryName: "intent", platform: .codex, projectPath: project.path)
        ])
        XCTAssertEqual(try harness.assignments().count, 2)
        XCTAssertEqual(recorder.events, ["deploy", "deploy:0:0", "category:0:0", "intent:2:0"])

        harness.context.delete(userIntent)
        try harness.context.save()
        harness.linkService.linkCalls.removeAll()
        recorder.events.removeAll()
        convergence.run(after: .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: true))
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            DeployRecordedLink(directoryName: "intent", platform: .codex, projectPath: nil)
        ])
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertEqual(try harness.assignments().map(\.projectID), [project.id])
        XCTAssertEqual(harness.fileService.symlinks, [
            harness.artifactPath(skill: skill, platform: .codex, project: project)
        ])
        XCTAssertEqual(recorder.events, ["deploy", "deploy:0:0", "category:0:0", "intent:1:0"])
        XCTAssertEqual(legacy.skillSlugs, [legacyOnly.directoryName])
    }
}
