import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    private func orderedRecords(_ records: [DeployIntentRecord]) -> [DeployIntentRecord] {
        records.sorted { ($0.machineID + $0.skillSlug + $0.platformRaw + ($0.projectKey ?? ""))
            < ($1.machineID + $1.skillSlug + $1.platformRaw + ($1.projectKey ?? "")) }
    }

    func testDeferredPairMakesPartialProgressAndCompletesOnLaterLaunch() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        let skill = try harness.seed(platforms: [.codex])
        let healthy = try harness.seed("healthy", platforms: [.cursor])
        let intent = MachineDeployIntent(machineID: harness.identity.id, skillSlug: "skill", platformRaw: "codex")
        let ledger = IntentAssignment(skillID: skill.id, platformRaw: "codex")
        harness.context.insert(intent)
        harness.context.insert(ledger)
        try harness.context.save()
        try harness.manifest.live.write(harness.manifest.live.snapshot(from: harness.context), toRoot: harness.root)
        let row = try XCTUnwrap(try harness.context.fetch(FetchDescriptor<ScenarioAssignment>()).first {
            $0.skillID == skill.id
        })
        let rowDate = row.assignedAt
        let before = try harness.deployedFiles()
        let handover = ScenarioHandover(machineIdentity: harness.identity, manifest: harness.manifest,
            root: harness.root, defaults: harness.defaults, deployState: { candidate, platform in
                if candidate.id == skill.id { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                return try HandoverDeployments(root: harness.root).platformVM.scenarioHandoverDeployState(
                    skill: candidate, platform: platform)
            }, fileService: harness.files, log: { harness.logs.append($0) })
        XCTAssertFalse(harness.launch(handover).ingestionNeedsRetry)
        let context = harness.freshContext()
        let remaining = try context.fetch(FetchDescriptor<ScenarioAssignment>())
        XCTAssertEqual(remaining.map(\.id), [row.id])
        XCTAssertEqual(remaining.first?.assignedAt, rowDate)
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertNotNil(harness.defaults.object(forKey: ScenarioHandover.activeKey))
        XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.key == intent.key
        }.map(\.persistentModelID), [intent.persistentModelID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<IntentAssignment>()).filter {
            $0.key == ledger.key
        }.map(\.persistentModelID), [ledger.persistentModelID])
        XCTAssertTrue(try context.fetch(FetchDescriptor<IntentAssignment>()).contains { $0.skillID == healthy.id })
        let expected = harness.unrelated + ["skill", "healthy"].map {
            DeployIntentRecord(machineID: harness.identity.id, skillSlug: $0,
                platformRaw: $0 == "skill" ? "codex" : "cursor", projectKey: nil)
        }
        XCTAssertEqual(orderedRecords(try harness.manifest.read(fromRoot: harness.root).deployIntents), orderedRecords(expected))
        XCTAssertEqual(orderedRecords(try harness.manifest.snapshot(from: context).deployIntents), orderedRecords(expected))
        XCTAssertTrue(harness.logs.contains { $0.contains("Deferred:") && $0.contains("skill") })
        let deploys = HandoverDeployments(root: harness.root)
        XCTAssertFalse(IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity,
            handoverIsComplete: { harness.defaults.bool(forKey: ScenarioHandover.doneKey) })
            .reconcile(context: context).hasFailures)
        XCTAssertEqual(deploys.createCalls + deploys.removeCalls, 0)
        try finishDeferredPair(harness: harness, deploys: deploys)
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    private func finishDeferredPair(harness: HandoverHarness, deploys: HandoverDeployments) throws {
        var retried: [String] = []
        let retry = ScenarioHandover(machineIdentity: harness.identity, manifest: harness.manifest,
            root: harness.root, defaults: harness.defaults, deployState: { candidate, platform in
                retried.append(candidate.directoryName + "/" + platform.rawValue)
                return try deploys.platformVM.scenarioHandoverDeployState(skill: candidate, platform: platform)
            }, fileService: harness.files)
        XCTAssertFalse(harness.launch(retry).ingestionNeedsRetry)
        XCTAssertEqual(retried, ["skill/codex"])
        XCTAssertTrue(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertNil(harness.defaults.object(forKey: ScenarioHandover.activeKey))
        XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 0)
    }

    func testDeferredPairKeepsCacheOnlyIntentOutOfHealthyManifestWrite() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        let skill = try harness.seed(platforms: [.codex])
        try harness.seed("healthy", platforms: [.cursor])
        let intent = MachineDeployIntent(machineID: harness.identity.id, skillSlug: "skill", platformRaw: "codex")
        let ledger = IntentAssignment(skillID: skill.id, platformRaw: "codex")
        harness.context.insert(intent)
        harness.context.insert(ledger)
        try harness.context.save()
        let before = try harness.deployedFiles()
        let handover = ScenarioHandover(machineIdentity: harness.identity, manifest: harness.manifest,
            root: harness.root, defaults: harness.defaults, deployState: { candidate, _ in
                if candidate.id == skill.id { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                return .realized
            }, fileService: harness.files)
        try handover.handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
            manifestWritten: true, rebuildSaveFailed: false, ingestionNeedsRetry: false))
        let context = harness.freshContext()
        XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.key == intent.key
        }.map(\.persistentModelID), [intent.persistentModelID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<IntentAssignment>()).filter {
            $0.key == ledger.key
        }.map(\.persistentModelID), [ledger.persistentModelID])
        let durable = try harness.manifest.read(fromRoot: harness.root).deployIntents
        XCTAssertTrue(durable.contains { $0.skillSlug == "skill" && $0.projectKey == nil })
        XCTAssertTrue(durable.contains { $0.skillSlug == "healthy" && $0.platformRaw == "cursor" })
        XCTAssertEqual(try context.fetch(FetchDescriptor<ScenarioAssignment>()).map(\.skillID), [skill.id])
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        let rebuild = StoreRebuildService(fileService: harness.files, manifestService: harness.manifest)
        let rebuilt = rebuild.rebuild(fromRoot: harness.root, context: context)
        XCTAssertFalse(rebuilt.saveFailed)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.key == intent.key
        }.map(\.persistentModelID), [intent.persistentModelID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<IntentAssignment>()).filter {
            $0.key == ledger.key
        }.map(\.persistentModelID), [ledger.persistentModelID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ScenarioAssignment>()).map(\.skillID), [skill.id])
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    func testOrphanStoreEntryClearsPriorIntentAndLedger() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        let skill = try harness.seed()
        for platform in ["codex", "cursor"] {
            harness.context.insert(MachineDeployIntent(machineID: harness.identity.id,
                skillSlug: "skill", platformRaw: platform))
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: platform))
        }
        try harness.context.save()
        try harness.manifest.live.write(harness.manifest.live.snapshot(from: harness.context), toRoot: harness.root)
        try harness.files.deleteDirectory(at: harness.root + "/skills/skill")
        let before = try harness.deployedFiles()
        try harness.handover().handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
            manifestWritten: true, rebuildSaveFailed: false, ingestionNeedsRetry: false))
        try harness.assertComplete([])
        XCTAssertEqual(harness.manifest.writes, 1)
        XCTAssertEqual(harness.nudges, 1)
        let deploys = HandoverDeployments(root: harness.root)
        XCTAssertFalse(IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity,
            handoverIsComplete: { true }).reconcile(context: harness.freshContext()).hasFailures)
        XCTAssertEqual(deploys.createCalls + deploys.removeCalls, 0)
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    func testSkillsFolderWithoutSearchPermissionDefersWholeHandover() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        let path = harness.root + "/skills"
        let before = try harness.deployedFiles()
        XCTAssertEqual(chmod(path, 0o644), 0)
        defer { chmod(path, 0o755) }
        // Darwin permits opendir with read permission alone; the gate must also prove search access.
        let opened = opendir(path)
        XCTAssertNotNil(opened)
        if let opened { closedir(opened) }
        XCTAssertThrowsError(try harness.files.checkDirectoryReadable(at: path))
        XCTAssertThrowsError(try harness.handover().handOver(context: harness.freshContext(),
            readiness: ScenarioHandoverReadiness(manifestWritten: true,
                rebuildSaveFailed: false, ingestionNeedsRetry: false)))
        XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
        XCTAssertNotNil(harness.defaults.object(forKey: ScenarioHandover.activeKey))
        XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
        XCTAssertEqual(harness.manifest.writes, 0)
        XCTAssertEqual(harness.nudges, 0)
        try harness.assertUnrelatedIntentsUnchanged()
        XCTAssertEqual(chmod(path, 0o755), 0)
        XCTAssertFalse(harness.launch().ingestionNeedsRetry)
        try harness.assertComplete()
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    func testDuplicateScenarioRowsUseOnePairClassificationAndOneStoreProbe() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Pensieve/Services/ScenarioHandover.swift"),
                                encoding: .utf8)
        XCTAssertFalse(source.contains("enum PairState"), "Use one handover state enum without a parallel mapping.")
        for first in ["realized", "absent", "unmanaged", "deferred"] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(first))
            defer { try? harness.cleanUp() }
            let skill = try harness.seed()
            let otherScenario = Scenario(name: "Other legacy scenario")
            otherScenario.skillSlugs = ["skill"]
            harness.context.insert(otherScenario)
            for platform in [PlatformTarget.codex, .cursor] {
                harness.context.insert(ScenarioAssignment(skillID: skill.id, platform: platform))
            }
            try harness.context.save()
            let probe = HandoverReadFileService(skillsRoot: harness.root + "/skills", failure: "none")
            var calls: [String: Int] = [:]
            let handover = ScenarioHandover(machineIdentity: harness.identity, manifest: harness.manifest,
                root: harness.root, defaults: harness.defaults, deployState: { _, platform in
                    calls[platform.rawValue, default: 0] += 1
                    if calls[platform.rawValue] != 1 { return first == "unmanaged" ? .realized : .unmanaged }
                    if first == "deferred" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                    return first == "realized" ? .realized : first == "absent" ? .absent : .unmanaged
                }, fileService: probe, log: { harness.logs.append($0) })
            try handover.handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
                manifestWritten: true, rebuildSaveFailed: false, ingestionNeedsRetry: false))
            XCTAssertEqual(calls, ["codex": 1, "cursor": 1], first)
            XCTAssertEqual(probe.entryChecks[harness.root + "/skills/skill"], 1, first)
            XCTAssertEqual(probe.folderChecks[harness.root + "/skills/skill"], 1, first)
            let context = harness.freshContext()
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), first == "deferred" ? 4 : 0, first)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), first == "realized" ? 2 : 0, first)
            XCTAssertEqual(harness.defaults.bool(forKey: ScenarioHandover.doneKey), first != "deferred", first)
            XCTAssertEqual(orderedRecords(try harness.manifest.snapshot(from: context).deployIntents),
                orderedRecords(try harness.manifest.read(fromRoot: harness.root).deployIntents), first)
            if first == "unmanaged" {
                XCTAssertEqual(harness.logs.filter { $0.contains("Left unmanaged:") }.count, 2)
                XCTAssertTrue(harness.logs.contains { $0.contains("2 left unmanaged") })
            }
        }
    }

    func testDeployProbeErrorsThrowAndDeferOwnership() throws {
        for code in [EACCES, EIO] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(String(code)))
            defer { try? harness.cleanUp() }
            try harness.seed(platforms: [.codex])
            let skill = try XCTUnwrap(try harness.context.fetch(FetchDescriptor<Skill>()).first)
            let faulty = HandoverReadFileService(skillsRoot: harness.root + "/skills", failure: "deploy-probe")
            faulty.probeError = code
            let deploys = HandoverDeployments(root: harness.root)
            let vm = PlatformViewModel(fileService: faulty, linkService: deploys, cursorCompiler: deploys,
                agentDetection: DeployStubDetection(installed: [.codex]), deployStateStore: .memoryBacked)
            XCTAssertThrowsError(try vm.scenarioHandoverDeployState(skill: skill, platform: .codex)) {
                XCTAssertEqual(($0 as NSError).domain, NSPOSIXErrorDomain)
                XCTAssertEqual(($0 as NSError).code, Int(code))
            }
            let handover = ScenarioHandover(machineIdentity: harness.identity, manifest: harness.manifest,
                root: harness.root, defaults: harness.defaults, deployState: vm.scenarioHandoverDeployState,
                fileService: faulty, log: { harness.logs.append($0) })
            let before = try harness.deployedFiles()
            XCTAssertFalse(harness.launch(handover).ingestionNeedsRetry)
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 1)
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
            XCTAssertEqual(harness.manifest.writes, 0)
            try harness.assertUnrelatedIntentsUnchanged()
            XCTAssertTrue(harness.logs.contains { $0.contains("Deferred:") && $0.contains("codex") })
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            try harness.assertComplete(["codex"])
            XCTAssertEqual(try harness.deployedFiles(), before)
        }
    }
}
