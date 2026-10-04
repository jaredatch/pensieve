import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    func testBadDeployPathsAndUnsafeStoreEntriesDoNotStallOtherPairs() throws {
        for kind in ["ENOTDIR", "EACCES", "ELOOP", "store-file", "store-link", "store-probe"] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(kind))
            defer { try? harness.cleanUp() }
            let skill = try harness.seed(platforms: [.codex])
            let healthy = try harness.seed("healthy", platforms: [.cursor])
            try installBadPath(kind, harness: harness)
            harness.context.insert(MachineDeployIntent(machineID: harness.identity.id,
                skillSlug: "skill", platformRaw: "codex"))
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "codex"))
            try harness.context.save()
            try harness.manifest.live.write(harness.manifest.live.snapshot(from: harness.context), toRoot: harness.root)
            let before = try harness.deployedFiles()
            let parent = harness.root + "/agents/codex"
            let parentIdentity = harness.files.fileIdentity(at: parent, followingLinks: false)
            let parentTarget = try? harness.files.symlinkTarget(at: parent)
            let faulty = HandoverReadFileService(skillsRoot: harness.root + "/skills",
                failure: kind == "EACCES" ? "deploy-probe" : kind == "store-probe" ? "bad-entry" : "none")
            let deploys = HandoverDeployments(root: harness.root)
            let platformVM = PlatformViewModel(fileService: faulty, linkService: deploys, cursorCompiler: deploys,
                agentDetection: DeployStubDetection(installed: [.codex, .cursor]), deployStateStore: .memoryBacked)
            if ["ENOTDIR", "EACCES", "ELOOP"].contains(kind) {
                XCTAssertNoThrow(try platformVM.scenarioHandoverDeployState(skill: skill, platform: .codex), kind)
            }
            let handover = ScenarioHandover(machineIdentity: harness.identity, manifest: harness.manifest,
                root: harness.root, defaults: harness.defaults, deployState: platformVM.scenarioHandoverDeployState,
                fileService: faulty, log: { harness.logs.append($0) })
            try handover.handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
                manifestWritten: true, rebuildSaveFailed: false, ingestionNeedsRetry: false))
            let context = harness.freshContext()
            try assertOwnershipAfterBadPath(context: context, harness: harness, healthy: healthy, kind: kind)
            XCTAssertEqual(faulty.directoryChecks, 1, kind)
            XCTAssertEqual(faulty.listings, 0, "handover must probe rather than enumerate skills: " + kind)
            XCTAssertFalse(IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity,
                handoverIsComplete: { true }).reconcile(context: context).hasFailures, kind)
            XCTAssertEqual(deploys.createCalls, 0, kind)
            XCTAssertEqual(deploys.removeCalls, 0, kind)
            XCTAssertEqual(try harness.deployedFiles(), before, kind)
            XCTAssertEqual(harness.files.fileIdentity(at: parent, followingLinks: false), parentIdentity, kind)
            XCTAssertEqual(try? harness.files.symlinkTarget(at: parent), parentTarget, kind)
        }
    }

    private func assertOwnershipAfterBadPath(context: ModelContext, harness: HandoverHarness,
                                             healthy: Skill, kind: String) throws {
        XCTAssertTrue(harness.defaults.bool(forKey: ScenarioHandover.doneKey), kind)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0, kind)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IntentAssignment>()).map(\.skillID), [healthy.id], kind)
        let expected = harness.unrelated + [DeployIntentRecord(machineID: harness.identity.id,
            skillSlug: "healthy", platformRaw: "cursor", projectKey: nil)]
        let durable = try harness.manifest.read(fromRoot: harness.root).deployIntents
        let cached = try harness.manifest.snapshot(from: context).deployIntents
        XCTAssertEqual(durable.count, expected.count, kind)
        XCTAssertEqual(cached.count, expected.count, kind)
        XCTAssertTrue(durable.allSatisfy(expected.contains), kind)
        XCTAssertTrue(cached.allSatisfy(expected.contains), kind)
        XCTAssertTrue(harness.logs.contains { $0.contains("Left unmanaged:") && $0.contains("skill") }, kind)
        XCTAssertFalse(harness.logs.contains { $0.contains("Dropped orphan:") }, kind)
    }

    private func installBadPath(_ kind: String, harness: HandoverHarness) throws {
        if ["ENOTDIR", "ELOOP"].contains(kind) {
            let parent = harness.root + "/agents/codex"
            try harness.files.deleteDirectory(at: parent)
            if kind == "ENOTDIR" {
                try harness.files.writeFile(at: parent, content: "user's agent folder is a file")
                harness.artifacts[0] = parent
            } else {
                try harness.files.createSymlink(at: parent, pointingTo: parent)
                // File attributes cannot traverse a self-loop; assert its link target and inode separately.
                harness.artifacts.removeFirst()
            }
        } else if kind == "store-file" || kind == "store-link" {
            let folder = harness.root + "/skills/skill"
            let parked = harness.root + "/parked"
            try FileManager.default.moveItem(atPath: folder, toPath: parked)
            if kind == "store-file" { try harness.files.writeFile(at: folder, content: "user's store entry") } else {
                try harness.files.createSymlink(at: folder, pointingTo: parked)
            }
            harness.artifacts.append(folder)
            harness.artifacts.append(parked + "/SKILL.md")
        }
    }
}
