import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    func testMissingArtifactsBecomeIntentAndReconcileWithoutFalseRealization() throws {
        for staleLedger in [false, true] {
            let harness = try HandoverHarness(defaults: isolatedDefaults("missing-\(staleLedger)"))
            defer { try? harness.cleanUp() }
            let skill = try harness.seed()
            for platform in [PlatformTarget.codex, .cursor] {
                try harness.files.deleteFile(at: harness.root + "/agents/" + platform.rawValue + "/skill")
                if staleLedger {
                    harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: platform.rawValue))
                }
            }
            try harness.context.save()
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            let context = harness.freshContext()
            XCTAssertTrue(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).deployIntents.filter {
                $0.skillSlug == "skill" && $0.projectKey == nil
            }.map(\.platformRaw).sorted(), ["codex", "cursor"])
            let deployments = HandoverDeployments(root: harness.root)
            deployments.allowCreation = true
            // Model canonical leaf admission without reaching the host's skills; deploy effects use the temp services.
            let platformVM = PlatformViewModel(fileService: DeployRecordingFileService(), linkService: deployments,
                cursorCompiler: deployments, agentDetection: DeployStubDetection(installed: [.codex, .cursor]),
                deployStateStore: .memoryBacked)
            let reconciler = IntentReconciler(platformVM: platformVM, machineIdentity: harness.identity,
                                             handoverIsComplete: { true })
            XCTAssertFalse(reconciler.reconcile(context: context).hasFailures)
            XCTAssertEqual(deployments.createCalls, 2)
            XCTAssertEqual(deployments.removeCalls, 0)
            try harness.assertComplete()
            XCTAssertTrue(harness.files.isSymlink(at: harness.root + "/agents/codex/skill"))
            XCTAssertTrue(harness.files.fileExists(at: harness.root + "/agents/cursor/skill"))
        }
    }

    func testHandoverBatches160RowsAndNudgesOnceAfterManifestWrite() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        for index in 0..<80 { try harness.seed("skill-\(index)") }
        let before = try harness.deployedFiles()
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        XCTAssertEqual(harness.manifest.writes, 1)
        XCTAssertEqual(harness.nudges, 1)
        let context = harness.freshContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 160)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0)
        XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).deployIntents.count, 162)
        XCTAssertEqual(try harness.deployedFiles(), before)
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        XCTAssertEqual(harness.manifest.writes, 1)
        XCTAssertEqual(harness.nudges, 1)
    }

    func testOwnershipSaveRetrySkipsAlreadyDurableManifestAndNudge() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        let before = try harness.deployedFiles()
        XCTAssertFalse(harness.launch(harness.handover(save: { _ in throw DeployStubFailure() })).ingestionNeedsRetry)
        XCTAssertEqual(harness.manifest.writes, 1)
        XCTAssertEqual(harness.nudges, 1)
        harness.manifest.failAllWrites = true
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete()
        XCTAssertEqual(harness.manifest.writes, 1)
        XCTAssertEqual(harness.nudges, 1)
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    func testHandoverEmitsEmptyProjectsInsteadOfRoundTrippingLegacyProjects() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        try harness.files.writeFile(at: harness.root + "/manifest/projects.yaml", content:
            "projects:\n  - {identity_key: \"marker:legacy\", identity_kind: \"marker\", name: \"Legacy\"}\n")
        XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).projects.count, 1)
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        XCTAssertEqual(try harness.files.readFile(at: harness.root + "/manifest/projects.yaml"), "projects:\n")
        try harness.assertComplete()
    }
}
