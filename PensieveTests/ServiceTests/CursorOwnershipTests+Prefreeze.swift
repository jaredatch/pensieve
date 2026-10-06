import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testHistoryOnlyCodexLinkWithoutSkillIsCountedAndRemoved() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        let path = artifactPath(.codex, project: project.path)
        try plant(owned: true, legacy: false, platform: .codex, path: path, project: project.path)
        harness.context.insert(DeployRecord(skillID: skill.id, platform: .codex,
            targetPath: path, contentHash: "historical", projectID: project.id))
        harness.context.delete(skill)
        try harness.context.save()
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 0)
        XCTAssertTrue(try harness.state.read().records.isEmpty)
        let model = ProjectRemovalModel()
        model.request(project, platformVM: harness.vm, context: harness.context)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.preview?.artifactCount, 1, "History alone must admit a project Codex file link")
        let result = model.confirm { project, preview in
            removeRegisteredProject(project, reconciler: CategoryReconciler(platformVM: harness.vm),
                platformVM: harness.vm, localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: preview, context: harness.context)
        }
        XCTAssertFalse(result.hasFailures)
        XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Project>()), 0)
    }

    @MainActor
    func testStaleHistoryKeepsCurrentLegacyRuleCandidateAndCountsRemoval() throws {
        for earlierEvidence in ["none", "state", "category", "intent", "live-history-category", "live-history-intent"] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let path = artifactPath(.cursor, project: project.path)
            skill.cursorConfig = CursorAdapterConfig(description: "Configured", globs: ["*.swift"], alwaysApply: true)
            try mapped.writeFile(at: path, content:
                "---\ndescription: Configured\nglobs: *.swift\nalwaysApply: true\n---\n\n# Body\n")
            if earlierEvidence == "state" {
                try reviewRecord(harness.state, path: path, target: .project(project))
            } else if earlierEvidence.hasSuffix("category") {
                harness.context.insert(SkillProjectAssignment(skillID: skill.id, projectID: project.id, platform: .cursor))
            } else if earlierEvidence.hasSuffix("intent") {
                harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor", projectID: project.id))
            }
            let historicalSkill = Skill(name: "Old Skill", directoryName: skill.directoryName)
            if earlierEvidence.hasPrefix("live-history") { harness.context.insert(historicalSkill) }
            harness.context.insert(DeployRecord(skillID: historicalSkill.id, platform: .cursor,
                targetPath: path, contentHash: "obsolete", projectID: project.id))
            try harness.context.save()
            let plan = try ProjectRemovalPlan.prepare(project: project, platformVM: harness.vm, context: harness.context)
            XCTAssertEqual(plan.preview.artifactCount, 1, earlierEvidence)
            XCTAssertEqual(plan.candidates.first?.pair.skill.id, skill.id,
                           "The live skill supplies legacy bytes and ledger identity")
            let result = removeRegisteredProject(project, reconciler: CategoryReconciler(platformVM: harness.vm),
                platformVM: harness.vm, localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: plan.preview, context: harness.context)
            XCTAssertFalse(result.hasFailures, earlierEvidence)
            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path), earlierEvidence)
            XCTAssertTrue(try harness.state.read().records.isEmpty)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        }
    }

    @MainActor
    func testDeploymentsTabDeselectRemovesOwnedAndPreservesForeignArtifacts() throws {
        try verifyIntentRouteRemoval(bulk: false)
    }

    @MainActor
    func testBulkSheetDeselectRemovesOwnedAndPreservesForeignArtifacts() throws {
        try verifyIntentRouteRemoval(bulk: true)
    }

    @MainActor
    private func verifyIntentRouteRemoval(bulk: Bool) throws {
        for platform in PlatformTarget.allCases {
            let scopes: [String?] = platform.supportsProjectScope ? [nil, root + "/project"] : [nil]
            for projectPath in scopes {
                for owned in [false, true] {
                    for legacy in platform == .cursor && owned ? [false, true] : [false] {
                        let harness = try contextAndVM()
                        let project = reviewProject(harness.context)
                        let target: DeployTarget = projectPath == nil ? .userWide : .project(project)
                        let path = artifactPath(platform, project: projectPath)
                        try plant(owned: owned, legacy: legacy, platform: platform, path: path, project: projectPath)
                        // Direct artifacts can predate intent tracking. The production fallback must remove them.
                        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
                        let model = secondReviewModel(harness)
                        let result: BatchResult
                        if !bulk {
                            result = try model.set(false, skill: skill, platform: platform,
                                target: target, context: harness.context)
                        } else {
                            let outcome = projectPath == nil
                                ? try model.retract(skills: [skill], platforms: [platform],
                                    machineIDs: [ProjectIntentHarness.localID], context: harness.context)
                                : try model.setProjectSelection(false, skills: [skill], platforms: [platform],
                                    project: project, context: harness.context)
                            guard case .localDeploy(let local) = outcome else { return XCTFail("Expected local removal") }
                            result = local
                        }
                        XCTAssertFalse(result.hasFailures, "\(bulk)/\(platform)/\(String(describing: projectPath))")
                        XCTAssertNil(model.error)
                        if owned {
                            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path), "\(platform)/\(legacy)")
                        } else if platform.usesSymlinks {
                            XCTAssertEqual(try mapped.symlinkTarget(at: path), root + "/foreign")
                        } else {
                            XCTAssertEqual(try mapped.readFile(at: path), "User rule")
                        }
                        if try mapped.entryExistsWithoutFollowingLinks(at: path) { try mapped.deleteFile(at: path) }
                    }
                }
            }
        }
    }
}
