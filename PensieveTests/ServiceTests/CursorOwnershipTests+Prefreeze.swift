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
    func testInvalidRecoveredHistorySlugsDoNotBlockValidProjectRemoval() throws {
        for invalidSlug in ["..", ".", "~x"] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let validPaths = [PlatformTarget.codex, .cursor].map { artifactPath($0, project: project.path) }
            for (platform, path) in zip([PlatformTarget.codex, .cursor], validPaths) {
                try plant(owned: true, legacy: false, platform: platform, path: path, project: project.path)
                harness.context.insert(DeployRecord(skillID: skill.id, platform: platform,
                    targetPath: path, contentHash: "valid", projectID: project.id))
            }
            harness.context.insert(DeployRecord(skillID: UUID(), platform: .cursor,
                targetPath: DeployPaths.cursorPath(directoryName: invalidSlug, projectPath: project.path),
                contentHash: "invalid", projectID: project.id))
            try harness.context.save()
            let plan = try ProjectRemovalPlan.prepare(project: project, platformVM: harness.vm, context: harness.context)
            XCTAssertEqual(plan.preview.artifactCount, 2, invalidSlug)
            XCTAssertEqual(Set(plan.candidates.map(\.path)), Set(validPaths), invalidSlug)
            let result = removeRegisteredProject(project, reconciler: CategoryReconciler(platformVM: harness.vm),
                platformVM: harness.vm, localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: plan.preview, context: harness.context)
            XCTAssertFalse(result.hasFailures, invalidSlug)
            for path in validPaths { XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path), invalidSlug) }
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Project>()), 0, invalidSlug)
        }
    }

    @MainActor
    func testRenamedLiveHistoryUUIDFallsBackToRecordedSlugOrSyntheticSkill() throws {
        for hasRecordedSkill in [true, false] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let platform: PlatformTarget = hasRecordedSkill ? .cursor : .codex
            let path = artifactPath(platform, project: project.path)
            try plant(owned: true, legacy: hasRecordedSkill, platform: platform, path: path, project: project.path)
            let renamed = Skill(name: "Renamed", directoryName: "renamed")
            harness.context.insert(renamed)
            let renamedPath = harness.vm.artifactPath(skill: renamed, platform: platform, target: .project(project))
            let renamedBytes = "---\n# pensieve: managed\n---\nRenamed rule"
            if platform == .cursor {
                try mapped.writeFile(at: renamedPath, content: renamedBytes)
            } else {
                try mapped.createSymlink(at: renamedPath, pointingTo: Constants.pensieveSkillsDir + "/renamed/SKILL.md")
            }
            harness.context.insert(DeployRecord(skillID: renamed.id, platform: platform,
                targetPath: path, contentHash: "before rename", projectID: project.id))
            if !hasRecordedSkill { harness.context.delete(skill) }
            try harness.context.save()
            let plan = try ProjectRemovalPlan.prepare(project: project, platformVM: harness.vm, context: harness.context)
            XCTAssertEqual(plan.preview.artifactCount, 1)
            XCTAssertEqual(plan.candidates.map(\.path), [path])
            XCTAssertEqual(plan.candidates.first?.pair.skill.directoryName, skill.directoryName)
            if hasRecordedSkill { XCTAssertEqual(plan.candidates.first?.pair.skill.id, skill.id) }
            let result = removeRegisteredProject(project, reconciler: CategoryReconciler(platformVM: harness.vm),
                platformVM: harness.vm, localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: plan.preview, context: harness.context)
            XCTAssertFalse(result.hasFailures)
            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
            if platform == .cursor {
                XCTAssertEqual(try mapped.readFile(at: renamedPath), renamedBytes)
            } else {
                XCTAssertEqual(try mapped.symlinkTarget(at: renamedPath), Constants.pensieveSkillsDir + "/renamed/SKILL.md")
            }
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Project>()), 0)
            try mapped.deleteFile(at: renamedPath)
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
        var cases = 0
        defer { XCTAssertEqual(cases, 22, "Every agent, scope and ownership case must run") }
        for platform in PlatformTarget.allCases {
            let scopes: [String?] = platform.supportsProjectScope ? [nil, root + "/project"] : [nil]
            for projectPath in scopes {
                for owned in [false, true] {
                    for legacy in platform == .cursor && owned ? [false, true] : [false] {
                        cases += 1
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
                            guard case .localDeploy(let local) = outcome else {
                                XCTFail("Expected local removal")
                                continue
                            }
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

extension CursorOwnershipTests {
    @MainActor
    func testProjectRemovalCountsAndRemovesUnicodeLinkAndRuleFromLocalEvidence() throws {
        for name in Self.ownershipSkillNames {
            for evidence in ["state", "history"] {
                try useOwnershipSkill(named: name)
                let harness = try contextAndVM()
                let project = Project(name: "Unicode project", path: root + "/\u{0301}project")
                project.identityKey = "github.com/owner/unicode"
                try files.createDirectory(at: project.path)
                harness.context.insert(project)
                for platform in [PlatformTarget.codex, .cursor] {
                    harness.vm.deploy(skill: skill, platform: platform, target: .project(project), context: harness.context)
                    XCTAssertNil(harness.vm.error, name.debugDescription)
                }
                if evidence == "history" {
                    try harness.state.replaceAll([])
                } else {
                    for record in try harness.context.fetch(FetchDescriptor<DeployRecord>()) {
                        harness.context.delete(record)
                    }
                }
                try harness.context.save()
                let paths = [PlatformTarget.codex, .cursor].map { artifactPath($0, project: project.path) }
                let model = ProjectRemovalModel()
                model.request(project, platformVM: harness.vm, context: harness.context)
                XCTAssertNil(model.error)
                XCTAssertEqual(model.preview?.artifactCount, 2, "\(name.debugDescription) / \(evidence)")
                let result = model.confirm { project, preview in
                    removeRegisteredProject(project, reconciler: CategoryReconciler(platformVM: harness.vm),
                        manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest",
                        platformVM: harness.vm, localMachineID: ProjectIntentHarness.localID,
                        confirmedPreview: preview, context: harness.context)
                }
                XCTAssertFalse(result.hasFailures)
                for path in paths { XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path)) }
                XCTAssertTrue(try harness.state.read().records.isEmpty)
                XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Project>()), 0)
            }
        }
    }

    func testLiteralUnicodeStoreTargetsPreserveLookalikesAndPruneOwnedLinks() throws {
        let storeRoot = root + "/caf\u{00e9}/skills"
        let lookalike = root + "/cafe\u{0301}/skills"
        let agentRoot = root + "/unicode-agent"
        try files.createDirectory(at: storeRoot)
        try files.createDirectory(at: agentRoot)
        let foreign = agentRoot + "/foreign"
        let owned = agentRoot + "/\u{0301}accent"
        let foreignTarget = lookalike + "/gone"
        try files.createSymlink(at: foreign, pointingTo: foreignTarget)
        try files.createSymlink(at: owned, pointingTo: storeRoot + "/\u{0301}accent")
        XCTAssertEqual(Data(try files.symlinkTarget(at: foreign).utf8), Data(foreignTarget.utf8))
        let reconciler = DeployReconciler(fileService: files,
            deployState: DeployStateStore(fileService: files, appSupportDir: root + "/unicode-support"),
            pensieveSkillsDir: storeRoot, agentSkillDirs: [agentRoot], cursorRulesDir: root + "/unicode-rules")
        XCTAssertEqual(reconciler.pruneDangling().removed, [owned])
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: owned))
        XCTAssertEqual(Data(try files.symlinkTarget(at: foreign).utf8), Data(foreignTarget.utf8))
    }

    func testProjectWritersUseLiteralUnicodeComponentsAndRejectSlashBearingNames() throws {
        let project = root + "/caf\u{00e9}"
        try files.createDirectory(at: project)
        let rule = project + "/\u{0301}interior/\u{0301}rule"
        try files.writeFileInProject(at: rule, content: "Rule bytes", projectPath: project)
        XCTAssertEqual(try files.readFile(at: rule), "Rule bytes")
        let link = project + "/\u{0301}interior/\u{0301}link"
        try files.createSymlinkInProject(at: link, pointingTo: rule, projectPath: project)
        XCTAssertEqual(Data(try files.symlinkTarget(at: link).utf8), Data(rule.utf8))
        let foreign = root + "/cafe\u{0301}/foreign"
        XCTAssertThrowsError(try files.writeFileInProject(at: foreign, content: "Foreign", projectPath: project))
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: foreign))
        XCTAssertTrue(ProjectDirectory.canAccess("/\u{0301}absolute"))
        for invalid in ["", ".", "..", "a/b", "a/\u{0301}b", "~\u{0301}home"] {
            let unsafe = Skill(name: "Unsafe", directoryName: invalid)
            XCTAssertThrowsError(try LinkService(fileService: mapped).link(
                skill: unsafe, platform: .codex, projectPath: project), invalid.debugDescription) { error in
                guard case LinkError.invalidPathComponent = error else {
                    return XCTFail("Expected invalid component, got \(error)")
                }
            }
        }
        try useOwnershipSkill(named: "caf\u{00e9}")
        let links = LinkService(fileService: mapped)
        let path = links.linkPath(skill: skill, platform: .claudeCode, projectPath: nil)
        let expected = Constants.pensieveSkillsDir + "/caf\u{00e9}"
        try links.link(skill: skill, platform: .claudeCode, projectPath: nil)
        XCTAssertEqual(Data(try mapped.symlinkTarget(at: path).utf8), Data(expected.utf8))
        XCTAssertTrue(links.isLinked(skill: skill, platform: .claudeCode, projectPath: nil))
        XCTAssertTrue(links.validateAll(skills: [skill]).isEmpty)
        try mapped.createSymlink(at: path, pointingTo: Constants.pensieveSkillsDir + "/cafe\u{0301}")
        XCTAssertFalse(links.isLinked(skill: skill, platform: .claudeCode, projectPath: nil))
        XCTAssertEqual(links.validateAll(skills: [skill]).map(\.linkPath), [path])
        try links.link(skill: skill, platform: .claudeCode, projectPath: nil)
        XCTAssertEqual(Data(try mapped.symlinkTarget(at: path).utf8), Data(expected.utf8))
        XCTAssertTrue(try links.unlink(skill: skill, platform: .claudeCode, projectPath: nil))
    }
}
