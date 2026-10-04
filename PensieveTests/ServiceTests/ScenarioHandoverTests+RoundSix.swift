import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    func testDeployClassificationUsesThrowingTypeAndLiteralTarget() throws {
        for kind in ["readlink", "symlink-boolean", "regular-boolean"] {
            for code in [EACCES, EIO] {
                let harness = try HandoverHarness(defaults: isolatedDefaults(kind + String(code)))
                defer { try? harness.cleanUp() }
                let platform: PlatformTarget = kind == "regular-boolean" ? .cursor : .codex
                let skill = try harness.seed(platforms: [platform])
                let intent = MachineDeployIntent(machineID: harness.identity.id, skillSlug: "skill",
                                                 platformRaw: platform.rawValue)
                let ledger = IntentAssignment(skillID: skill.id, platformRaw: platform.rawValue)
                harness.context.insert(intent)
                harness.context.insert(ledger)
                try harness.context.save()
                try harness.manifest.live.write(harness.manifest.live.snapshot(from: harness.context), toRoot: harness.root)
                let before = try harness.deployedFiles()
                let faulty = HandoverReadFileService(skillsRoot: harness.root + "/skills", failure: kind)
                faulty.probeError = code
                let vm = probeViewModel(harness: harness, faulty: faulty)
                if kind == "readlink" {
                    XCTAssertThrowsError(try vm.scenarioHandoverDeployState(skill: skill, platform: platform)) {
                        XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
                        XCTAssertEqual(($0 as NSError).code, Int(code))
                    }
                } else {
                    XCTAssertEqual(try vm.scenarioHandoverDeployState(skill: skill, platform: platform), .realized, kind)
                }
                XCTAssertEqual(faulty.entryChecks[harness.root + "/agents/" + platform.rawValue + "/skill"], 1, kind)
                XCTAssertEqual(faulty.deployBooleanChecks, 0, kind)
                XCTAssertEqual(faulty.readlinkChecks, platform.usesSymlinks ? 1 : 0, kind)
                let handover = ScenarioHandover(machineIdentity: harness.identity, manifest: harness.manifest,
                    root: harness.root, defaults: harness.defaults, deployState: vm.scenarioHandoverDeployState,
                    fileService: faulty)
                try handover.handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
                    manifestWritten: true, rebuildSaveFailed: false, ingestionNeedsRetry: false))
                let context = harness.freshContext()
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), kind == "readlink" ? 1 : 0)
                XCTAssertEqual(harness.defaults.bool(forKey: ScenarioHandover.doneKey), kind != "readlink")
                XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
                    $0.key == intent.key
                }.map(\.persistentModelID), [intent.persistentModelID], kind)
                XCTAssertEqual(try context.fetch(FetchDescriptor<IntentAssignment>()).map(\.persistentModelID),
                               [ledger.persistentModelID], kind)
                XCTAssertEqual(harness.manifest.writes, 0, kind)
                try harness.assertUnrelatedIntentsUnchanged()
                XCTAssertFalse(harness.launch().ingestionNeedsRetry)
                try harness.assertComplete([platform.rawValue])
                XCTAssertEqual(try harness.deployedFiles(), before, kind)
            }
        }
    }

    func testStoreResolutionErrorsDeferAndUnsafeLeavesStayUnmanaged() throws {
        for kind in ["resolve-folder", "resolve-base", "resolve-escape",
                     "missing-leaf", "leaf-link", "leaf-folder", "leaf-fifo"] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(kind))
            defer { try? harness.cleanUp() }
            let skill = try harness.seed(platforms: [.codex])
            let healthy = try harness.seed("healthy", platforms: [.cursor])
            let intent = MachineDeployIntent(machineID: harness.identity.id, skillSlug: "skill", platformRaw: "codex")
            let ledger = IntentAssignment(skillID: skill.id, platformRaw: "codex")
            harness.context.insert(intent)
            harness.context.insert(ledger)
            try harness.context.save()
            try harness.manifest.live.write(harness.manifest.live.snapshot(from: harness.context), toRoot: harness.root)
            let before = try harness.deployedFiles()
            try installUnsafeLeaf(kind, harness: harness)
            let faulty = HandoverReadFileService(skillsRoot: harness.root + "/skills", failure: kind)
            faulty.probeError = kind == "resolve-base" ? EACCES : EIO
            try harness.handover(fileService: faulty).handOver(context: harness.freshContext(),
                readiness: ScenarioHandoverReadiness(manifestWritten: true,
                    rebuildSaveFailed: false, ingestionNeedsRetry: false))
            let deferred = kind == "resolve-folder" || kind == "resolve-base"
            let context = harness.freshContext()
            XCTAssertEqual(try context.fetch(FetchDescriptor<ScenarioAssignment>()).map(\.skillID),
                           deferred ? [skill.id] : [], kind)
            XCTAssertEqual(harness.defaults.bool(forKey: ScenarioHandover.doneKey), !deferred, kind)
            XCTAssertTrue(try context.fetch(FetchDescriptor<IntentAssignment>()).contains { $0.skillID == healthy.id }, kind)
            XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
                $0.key == intent.key
            }.map(\.persistentModelID), deferred ? [intent.persistentModelID] : [], kind)
            XCTAssertEqual(try context.fetch(FetchDescriptor<IntentAssignment>()).filter {
                $0.key == ledger.key
            }.map(\.persistentModelID), deferred ? [ledger.persistentModelID] : [], kind)
            XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).deployIntents.contains {
                $0.skillSlug == "skill" && $0.projectKey == nil
            }, deferred, kind)
            XCTAssertEqual(faulty.entryChecks[harness.root + "/skills/skill"], 1, kind)
            XCTAssertEqual(faulty.resolutionChecks[harness.root + "/skills/skill"], 1, kind)
            XCTAssertFalse(harness.logs.contains { $0.contains("Dropped orphan:") }, kind)
            XCTAssertTrue(harness.logs.contains {
                $0.contains(deferred ? "Deferred:" : "Left unmanaged:") && $0.contains("skill")
            }, kind)
            XCTAssertEqual(try harness.deployedFiles(), before, kind)
            if deferred {
                try harness.handover().handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
                    manifestWritten: true, rebuildSaveFailed: false, ingestionNeedsRetry: false))
                XCTAssertTrue(harness.defaults.bool(forKey: ScenarioHandover.doneKey), kind)
                XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 0, kind)
                XCTAssertEqual(try harness.deployedFiles(), before, kind)
            }
        }
    }

    func testUnrepresentableAndMissingSkillRowsNeedNoSkillsAccess() throws {
        for kind in ["unrepresentable", "missing-row", "mixed"] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(kind))
            defer { try? harness.cleanUp() }
            if kind != "missing-row" { try harness.seed("odd slug", platforms: [.codex]) }
            if kind != "unrepresentable" {
                harness.context.insert(ScenarioAssignment(skillID: UUID(), platform: .cursor))
                try harness.context.save()
            }
            // No row requires the store, even when it has disappeared entirely.
            if harness.files.directoryExists(at: harness.root + "/skills") {
                try harness.files.deleteDirectory(at: harness.root + "/skills")
            }
            let before = try harness.deployedFiles()
            let faulty = HandoverReadFileService(skillsRoot: harness.root + "/skills", failure: "listing")
            try harness.handover(fileService: faulty).handOver(context: harness.freshContext(),
                readiness: ScenarioHandoverReadiness(manifestWritten: true,
                    rebuildSaveFailed: false, ingestionNeedsRetry: false))
            XCTAssertEqual(faulty.directoryChecks, 0, kind)
            XCTAssertTrue(faulty.entryChecks.isEmpty, kind)
            XCTAssertTrue(harness.defaults.bool(forKey: ScenarioHandover.doneKey), kind)
            XCTAssertNil(harness.defaults.object(forKey: ScenarioHandover.activeKey), kind)
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 0, kind)
            XCTAssertEqual(harness.manifest.writes, 0, kind)
            XCTAssertEqual(harness.nudges, 0, kind)
            try harness.assertUnrelatedIntentsUnchanged()
            XCTAssertEqual(try harness.deployedFiles(), before, kind)
        }
    }

    private func probeViewModel(harness: HandoverHarness, faulty: HandoverReadFileService) -> PlatformViewModel {
        let logical = (DeployPaths.linkPath(directoryName: "skill", platform: .codex,
                                           projectPath: nil) as NSString).deletingLastPathComponent
        let adapter = LinkServiceCanonicalDirectoryFileService(wrapped: faulty, pathMappings: [
            (Constants.pensieveSkillsDir, harness.root + "/skills"),
            (logical, harness.root + "/agents/codex")
        ])
        return PlatformViewModel(fileService: adapter, linkService: LinkService(fileService: adapter),
            cursorCompiler: HandoverDeployments(root: harness.root),
            agentDetection: DeployStubDetection(installed: [.codex, .cursor]), deployStateStore: .memoryBacked)
    }

    private func installUnsafeLeaf(_ kind: String, harness: HandoverHarness) throws {
        guard kind.hasPrefix("leaf-") || kind == "missing-leaf" else { return }
        let leaf = harness.root + "/skills/skill/SKILL.md"
        try harness.files.deleteFile(at: leaf)
        switch kind {
        case "leaf-link": try harness.files.createSymlink(at: leaf, pointingTo: harness.root + "/skills/healthy/SKILL.md")
        case "leaf-folder": try harness.files.createDirectory(at: leaf)
        case "leaf-fifo": XCTAssertEqual(mkfifo(leaf, 0o600), 0)
        default: break
        }
    }
}
