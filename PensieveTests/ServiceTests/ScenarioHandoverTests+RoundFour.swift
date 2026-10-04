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
        let otherIntent = MachineDeployIntent(machineID: harness.identity.id, skillSlug: "skill", platformRaw: "hermes")
        harness.context.insert(otherIntent)
        try prior.seed(skill: skill, platform: occupant.platform, harness: harness)
        let before = occupant.absent ? nil : try harness.deployedFiles()
        let priorRows = try harness.context.fetch(FetchDescriptor<IntentAssignment>())
        let priorRowID = priorRows.first?.persistentModelID
        try harness.handover().handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
            manifestWritten: true, rebuildSaveFailed: false, ingestionNeedsRetry: false))
        let context = harness.freshContext()
        let wantsIntent = !occupant.unmanaged
        let wantsLedger = !occupant.unmanaged && !occupant.absent
        try assertCellOwnership(context: context, harness: harness, platform: occupant.platform,
                                intent: wantsIntent, ledger: wantsLedger, label: label)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0, label)
        XCTAssertTrue(harness.defaults.bool(forKey: ScenarioHandover.doneKey), label)
        if let before { XCTAssertEqual(try harness.deployedFiles(), before, "handover: " + label) }
        let reconciler = IntentReconciler(platformVM: realDeployments(harness: harness),
            machineIdentity: harness.identity, handoverIsComplete: { true })
        let result = reconciler.reconcile(context: context)
        print("HANDOVER_CELL \(label) failures=\(result.hasFailures) outcomes=\(result.outcomes.count)")
        XCTAssertFalse(result.hasFailures, "convergence: " + label)
        if let before {
            if try harness.files.entryExistsWithoutFollowingLinks(at: path) {
                XCTAssertEqual(try harness.deployedFiles(), before, "convergence: " + label)
            } else {
                XCTFail("convergence removed occupant: " + label)
            }
        } else {
            XCTAssertTrue(try harness.files.entryExistsWithoutFollowingLinks(at: path), "deployed: " + label)
        }
        try assertCellOwnership(context: context, harness: harness, platform: occupant.platform,
                                intent: wantsIntent, ledger: occupant.absent || wantsLedger, label: label)
        if !occupant.unmanaged, !occupant.absent, prior.ledger {
            let after = try context.fetch(FetchDescriptor<IntentAssignment>()).first
            XCTAssertEqual(after?.persistentModelID, priorRowID, "ledger identity: " + label)
        }
        if occupant.unmanaged {
            XCTAssertTrue(harness.logs.contains { $0.contains("Left unmanaged:") }, label)
            XCTAssertEqual(harness.manifest.writes, prior.intent ? 1 : 0, "removal-only manifest write: " + label)
        }
        try assertOtherPair(context: context, harness: harness, intent: otherIntent, label: label)
    }

    private func assertOtherPair(context: ModelContext, harness: HandoverHarness,
                                 intent otherIntent: MachineDeployIntent, label: String) throws {
        let otherRecord = DeployIntentRecord(machineID: harness.identity.id, skillSlug: "skill",
                                             platformRaw: "hermes", projectKey: nil)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.key == otherIntent.key
        }.map(\.persistentModelID), [otherIntent.persistentModelID], "other local pair: " + label)
        XCTAssertTrue(try harness.manifest.read(fromRoot: harness.root).deployIntents.contains(otherRecord), label)
        try harness.assertUnrelatedIntentsUnchanged()
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
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), ledger ? 1 : 0, "ledger: " + label)
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
