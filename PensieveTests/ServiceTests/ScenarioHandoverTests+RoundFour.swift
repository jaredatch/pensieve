import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    func testEveryOccupantAndPriorOwnershipSurvivesHandoverAndRealConvergence() throws {
        var cells = 0
        for occupant in HandoverOccupant.allCases {
            for prior in HandoverPriorOwnership.allCases {
                try verifyCell(occupant: occupant, prior: prior)
                cells += 1
            }
        }
        XCTAssertEqual(cells, 32)
    }

    private func verifyCell(occupant: HandoverOccupant, prior: HandoverPriorOwnership) throws {
        let label = "\(occupant.rawValue)/\(prior.rawValue)"
        let harness = try HandoverHarness(defaults: isolatedDefaults(label))
        defer { try? harness.cleanUp() }
        let skill = try harness.seed(platforms: [occupant.platform])
        let path = try XCTUnwrap(harness.artifacts.first)
        try occupant.install(path: path, harness: harness)
        if occupant.absent { harness.artifacts.removeFirst() }
        let installed = try seedInstalledOtherPair(harness: harness)
        let otherIntent = MachineDeployIntent(machineID: harness.identity.id, skillSlug: "skill", platformRaw: "hermes")
        harness.context.insert(otherIntent)
        try prior.seed(skill: skill, platform: occupant.platform, harness: harness)
        let before = try harness.deployedFiles()
        let priorRows = try harness.context.fetch(FetchDescriptor<IntentAssignment>())
        let priorRowID = priorRows.first { $0.skillID == skill.id }?.persistentModelID
        try harness.handover().handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
            manifestWritten: true, rebuildSaveFailed: false, ingestionNeedsRetry: false))
        let context = harness.freshContext()
        let wantsIntent = !occupant.unmanaged
        let wantsLedger = !occupant.unmanaged && !occupant.absent
        try assertCellOwnership(context: context, harness: harness, platform: occupant.platform,
                                intent: wantsIntent, ledger: wantsLedger, label: label)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0, label)
        XCTAssertTrue(harness.defaults.bool(forKey: ScenarioHandover.doneKey), label)
        XCTAssertEqual(try harness.deployedFiles(), before, "handover: " + label)
        try assertOtherPair(context: context, harness: harness, intent: otherIntent, installed: installed, label: label)
        let reconciler = IntentReconciler(platformVM: realDeployments(harness: harness),
            machineIdentity: harness.identity, handoverIsComplete: { true })
        let result = reconciler.reconcile(context: context)
        print("HANDOVER_CELL \(label) failures=\(result.hasFailures) outcomes=\(result.outcomes.count)")
        XCTAssertFalse(result.hasFailures, "convergence: " + label)
        XCTAssertEqual(try harness.deployedFiles(), before, "convergence: " + label)
        XCTAssertTrue(try harness.files.entryExistsWithoutFollowingLinks(at: path), "occupant/deploy: " + label)
        try assertCellOwnership(context: context, harness: harness, platform: occupant.platform,
                                intent: wantsIntent, ledger: occupant.absent || wantsLedger, label: label)
        if !occupant.unmanaged, !occupant.absent, prior.ledger {
            let after = try context.fetch(FetchDescriptor<IntentAssignment>()).first { $0.skillID == skill.id }
            XCTAssertEqual(after?.persistentModelID, priorRowID, "ledger identity: " + label)
        }
        if occupant.unmanaged {
            XCTAssertTrue(harness.logs.contains { $0.contains("Left unmanaged:") }, label)
            XCTAssertEqual(harness.manifest.writes, prior.intent ? 1 : 0, "removal-only manifest write: " + label)
        }
        try assertOtherPair(context: context, harness: harness, intent: otherIntent, installed: installed, label: label)
    }

    private func assertOtherPair(context: ModelContext, harness: HandoverHarness,
                                 intent otherIntent: MachineDeployIntent,
                                 installed: (intent: MachineDeployIntent, ledger: IntentAssignment), label: String) throws {
        let otherSkill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first {
            $0.directoryName == "unrelated"
        }, "installed unrelated skill must participate in convergence: " + label)
        XCTAssertTrue(realDeployments(harness: harness).installedPlatforms().contains(.codex), label)
        XCTAssertTrue(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/agents/codex/unrelated"), label)
        XCTAssertTrue(try context.fetch(FetchDescriptor<IntentAssignment>()).contains {
            $0.skillID == otherSkill.id && $0.platformRaw == "codex" && $0.projectID == nil
        }, label)
        let otherRecord = DeployIntentRecord(machineID: harness.identity.id, skillSlug: "skill",
                                             platformRaw: "hermes", projectKey: nil)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.key == otherIntent.key
        }.map(\.persistentModelID), [otherIntent.persistentModelID], "other local pair: " + label)
        XCTAssertTrue(try harness.manifest.read(fromRoot: harness.root).deployIntents.contains(otherRecord), label)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.key == installed.intent.key
        }.map(\.persistentModelID), [installed.intent.persistentModelID], "installed unrelated intent: " + label)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IntentAssignment>()).filter {
            $0.key == installed.ledger.key
        }.map(\.persistentModelID), [installed.ledger.persistentModelID], "installed unrelated ledger: " + label)
        let installedRecord = DeployIntentRecord(machineID: harness.identity.id,
            skillSlug: "unrelated", platformRaw: "codex", projectKey: nil)
        let durable = try harness.manifest.read(fromRoot: harness.root).deployIntents
        let cached = try harness.manifest.snapshot(from: context).deployIntents
        let expected = harness.unrelated + [otherRecord, installedRecord]
        for records in [durable, cached] {
            let unrelated = records.filter { $0.skillSlug != "skill" || $0.projectKey != nil || $0.platformRaw == "hermes" }
            XCTAssertEqual(unrelated.count, expected.count, label)
            XCTAssertTrue(unrelated.allSatisfy(expected.contains), label)
        }
    }

    private func assertCellOwnership(context: ModelContext, harness: HandoverHarness, platform: PlatformTarget,
                                     intent: Bool, ledger: Bool, label: String) throws {
        let cached = try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.machineID == harness.identity.id && $0.skillSlug == "skill"
                && $0.platformRaw == platform.rawValue && $0.projectKey == nil
        }
        let durable = try harness.manifest.read(fromRoot: harness.root).deployIntents.filter {
            $0.machineID == harness.identity.id && $0.skillSlug == "skill"
                && $0.platformRaw == platform.rawValue && $0.projectKey == nil
        }
        XCTAssertEqual(cached.count, intent ? 1 : 0, "cached intent: " + label)
        XCTAssertEqual(durable.count, intent ? 1 : 0, "durable intent: " + label)
        let skillID = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first {
            $0.directoryName == "skill"
        }).id
        let rows = try context.fetch(FetchDescriptor<IntentAssignment>()).filter {
            $0.skillID == skillID && $0.platformRaw == platform.rawValue && $0.projectID == nil
        }
        XCTAssertEqual(rows.count, ledger ? 1 : 0, "ledger: " + label)
    }

    private func seedInstalledOtherPair(harness: HandoverHarness) throws
        -> (intent: MachineDeployIntent, ledger: IntentAssignment) {
        let skill = Skill(name: "Unrelated", skillDescription: "Description", directoryName: "unrelated")
        let intent = MachineDeployIntent(machineID: harness.identity.id, skillSlug: "unrelated", platformRaw: "codex")
        let ledger = IntentAssignment(skillID: skill.id, platformRaw: "codex")
        harness.context.insert(skill)
        harness.context.insert(intent)
        harness.context.insert(ledger)
        try harness.files.createDirectory(at: harness.root + "/skills/unrelated")
        try harness.files.writeFile(at: harness.root + "/skills/unrelated/SKILL.md",
            content: "---\nname: Unrelated\ndescription: Description\n---\nUnrelated bytes")
        let path = harness.root + "/agents/codex/unrelated"
        try harness.files.createSymlink(at: path, pointingTo: harness.root + "/skills/unrelated")
        harness.artifacts.append(path)
        return (intent, ledger)
    }

    private func realDeployments(harness: HandoverHarness) -> PlatformViewModel {
        // Translate production deploy paths into this cell's temp tree. LinkService and CursorCompiler
        // remain real; all file mutations use FileService through the existing mapping double.
        let codexRoot = (DeployPaths.linkPath(directoryName: "skill", platform: .codex, projectPath: nil) as NSString)
            .deletingLastPathComponent
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: harness.files, pathMappings: [
            (Constants.pensieveSkillsDir, harness.root + "/skills"),
            (codexRoot, harness.root + "/agents/codex"),
            (Constants.cursorUserRulesDir + "/skill.mdc", harness.root + "/agents/cursor/skill")
        ], physicalSandbox: harness.root)
        return PlatformViewModel(fileService: mapped, linkService: LinkService(fileService: mapped),
            cursorCompiler: CursorCompiler(fileService: mapped, skillStore: SkillStore(fileService: mapped)),
            agentDetection: DeployStubDetection(installed: [.codex, .cursor]), deployStateStore: .memoryBacked)
    }
}

private enum HandoverOccupant: String, CaseIterable {
    case workingLink, otherLink, relativeLink, danglingLink, folder, nothing, cursorFile, cursorNothing

    var platform: PlatformTarget { self == .cursorFile || self == .cursorNothing ? .cursor : .codex }
    var absent: Bool { self == .nothing || self == .cursorNothing }
    var unmanaged: Bool { [.otherLink, .relativeLink, .danglingLink, .folder].contains(self) }

    @MainActor
    func install(path: String, harness: HandoverHarness) throws {
        try harness.files.deleteFile(at: path)
        switch self {
        case .workingLink:
            try harness.files.createSymlink(at: path, pointingTo: harness.root + "/skills/skill")
        case .otherLink:
            try harness.files.createDirectory(at: harness.root + "/other")
            try harness.files.writeFile(at: harness.root + "/other/SKILL.md", content: "user's bytes")
            try harness.files.createSymlink(at: path, pointingTo: harness.root + "/other")
            harness.artifacts.append(harness.root + "/other/SKILL.md")
        case .relativeLink:
            try harness.files.createSymlink(at: path, pointingTo: "../../skills/skill")
        case .danglingLink:
            try harness.files.createSymlink(at: path, pointingTo: harness.root + "/missing")
        case .folder:
            try harness.files.createDirectory(at: path)
            try harness.files.writeFile(at: path + "/SKILL.md", content: "user's bytes")
            harness.artifacts.append(path + "/SKILL.md")
        case .cursorFile:
            try harness.files.writeFile(at: path, content: CursorMDC.generate(directoryName: "skill",
                description: "Description", cursorConfig: nil, body: "Body"))
        case .nothing, .cursorNothing: break
        }
    }
}

private enum HandoverPriorOwnership: String, CaseIterable {
    case none, intentOnly, intentAndLedger, ledgerOnly

    var intent: Bool { self == .intentOnly || self == .intentAndLedger }
    var ledger: Bool { self == .ledgerOnly || self == .intentAndLedger }

    @MainActor
    func seed(skill: Skill, platform: PlatformTarget, harness: HandoverHarness) throws {
        if intent {
            harness.context.insert(MachineDeployIntent(machineID: harness.identity.id,
                skillSlug: "skill", platformRaw: platform.rawValue))
        }
        if ledger { harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: platform.rawValue)) }
        try harness.context.save()
        try harness.manifest.live.write(harness.manifest.live.snapshot(from: harness.context), toRoot: harness.root)
    }
}
