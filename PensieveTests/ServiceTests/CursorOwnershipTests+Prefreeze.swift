import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    func testJoiningFirstSkillNamesNeverDeleteOrOverwriteForeignOccupants() throws {
        let names = ["\u{0301}accent", "\u{0903}spacing", "\u{20dd}enclosing", "\u{200d}joiner", "\u{1f3fb}modifier"]
        let text = "Foreign occupant's bytes"
        let sentinel = Data(text.utf8)
        let foreign = root + "/foreign-target"
        try files.writeFile(at: foreign, content: text)
        for name in names {
            try useOwnershipSkill(named: name)
            for platform in PlatformTarget.allCases {
                let scopes: [String?] = platform.supportsProjectScope ? [nil, root + "/project"] : [nil]
                for project in scopes {
                    let path = artifactPath(platform, project: project)
                    let physical = root + "/joining/" + platform.rawValue
                        + (project == nil ? "/user/" : "/project/") + name
                    // Exact leaf mappings avoid the shared fixture's own grapheme-prefix residual.
                    let boundary = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [
                        (TestPaths.skillsDir + "/" + name, root + "/store/skills/" + name),
                        (path, physical)
                    ], physicalSandbox: root)
                    let links = TestPaths.linkService(fileService: boundary)
                    let rules = CursorCompiler(fileService: boundary, skillStore: store,
                        userRulesDirectory: TestPaths.deployPaths.cursorUserRulesDirectory)
                    for occupant in ["link", "file", "directory"] {
                        if occupant == "link" { try files.createSymlink(at: physical, pointingTo: foreign) } else {
                            try files.writeFile(at: physical + (occupant == "directory" ? "/payload" : ""),
                                                content: text)
                        }
                        let type = try files.entryTypeWithoutFollowingLinks(at: physical)
                        let contents: () throws -> Data = {
                            if occupant == "link" { return Data(try self.files.symlinkTarget(at: physical).utf8) }
                            return try self.files.readData(at: physical + (occupant == "directory" ? "/payload" : ""))
                        }
                        let before = try contents()
                        let label = "\(name.debugDescription) / \(platform) / project=\(project != nil) / \(occupant)"
                        XCTAssertThrowsError(try platform.usesSymlinks
                            ? links.link(skill: skill, platform: platform, projectPath: project)
                            : rules.compile(skill: skill, projectPath: project), label) { error in
                            self.assertForeignOccupantRefusal(error, path: path, label: label)
                        }
                        XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: physical), type, label)
                        XCTAssertEqual(try contents(), before, label)
                        XCTAssertNoThrow(try platform.usesSymlinks
                            ? links.unlink(skill: skill, platform: platform, projectPath: project)
                            : rules.remove(skill: skill, projectPath: project), label)
                        XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: physical), type, label)
                        XCTAssertEqual(try contents(), before, label)
                        XCTAssertEqual(try files.readData(at: foreign), sentinel, label)
                        try files.deleteFile(at: physical)
                    }
                }
            }
        }
    }

    private func assertForeignOccupantRefusal(_ error: Error, path: String, label: String) {
        if case ArtifactOwnershipError.occupiedPath(let occupied) = error {
            XCTAssertEqual(occupied, path, label)
        } else if case LinkError.occupiedByRealPath(let occupied) = error {
            XCTAssertEqual(occupied, path, label)
        } else {
            XCTFail("Expected foreign-occupant refusal, got \(error): \(label)")
        }
    }

    private func useOwnershipSkill(named name: String) throws {
        skill = Skill(name: name, skillDescription: "Description", directoryName: name)
        try store.writeBody(directoryName: name, body: "# Body")
    }

    func testCanonicalEquivalentSkillTargetsAreOwnedRealizedHealedAndRemoved() throws {
        try useOwnershipSkill(named: "caf\u{00e9}")
        let links = TestPaths.linkService(fileService: mapped)
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let scopes: [String?] = platform.supportsProjectScope ? [nil, root + "/project"] : [nil]
            for project in scopes {
                let path = links.linkPath(skill: skill, platform: platform, projectPath: project)
                let expected = links.targetPath(skill: skill, platform: platform, projectPath: project)
                try mapped.createSymlink(at: path, pointingTo: expected.decomposedStringWithCanonicalMapping)
                let actual = try mapped.symlinkTarget(at: path)
                XCTAssertFalse(actual.utf8.elementsEqual(expected.utf8), "The fixture must have distinct NFC/NFD bytes")
                XCTAssertTrue(try links.ownsArtifact(skill: skill, platform: platform, projectPath: project))
                XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: project))
                if project == nil { XCTAssertTrue(links.validateAll(skills: [skill]).isEmpty) }
                XCTAssertNoThrow(try links.link(skill: skill, platform: platform, projectPath: project))
                XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: project))
                XCTAssertTrue(try links.unlink(skill: skill, platform: platform, projectPath: project))
                XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
                // An older install's canonically equivalent target naming another skill is healable.
                try mapped.createSymlink(at: path, pointingTo:
                    (TestPaths.skillsDir + "/caf\u{00e9}-old"
                     + (platform == .codex && project != nil ? "/SKILL.md" : "")).decomposedStringWithCanonicalMapping)
                XCTAssertNoThrow(try links.link(skill: skill, platform: platform, projectPath: project))
                XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: project))
                XCTAssertTrue(try links.unlink(skill: skill, platform: platform, projectPath: project))
            }
        }
    }

    func testCanonicalEquivalentStoreTargetsRemainOwnedAndPruneDanglingLinks() throws {
        let skills = root + "/caf\u{00e9}/skills"
        let agents = root + "/caf\u{00e9}-home/agent/skills"
        let ownership = DeployArtifactOwnership(fileService: files)
        let reconciler = DeployReconciler(fileService: files,
            deployState: DeployStateStore(fileService: files, appSupportDir: root + "/canonical-support"),
            pensieveSkillsDir: skills, agentSkillDirs: [.init(platform: .claudeCode, path: agents)],
            cursorRulesDir: root + "/canonical-rules")
        for (name, linksFile) in [("owned", false), ("caf\u{00e9}", false), ("owned-file", true)] {
            let expected = skills + "/" + name + (linksFile ? "/SKILL.md" : "")
            let target = expected.decomposedStringWithCanonicalMapping
            let path = agents + "/" + name
            try files.writeFile(at: skills + "/" + name + "/SKILL.md", content: "Sentinel")
            try files.createSymlink(at: path, pointingTo: target)
            XCTAssertFalse(try files.symlinkTarget(at: path).utf8.elementsEqual(expected.utf8))
            XCTAssertEqual(try ownership.link(at: path, skillsDirectory: skills, linksFile: linksFile), .owned)
            XCTAssertTrue(files.fileExists(at: target) || files.directoryExists(at: target),
                          "APFS resolves the decomposed spelling")
            XCTAssertTrue(reconciler.pruneDangling().removed.isEmpty, "A live target stays realized")
            try files.deleteDirectory(at: skills + "/" + name)
            if !linksFile {
                XCTAssertEqual(reconciler.pruneDangling().removed, [path])
                XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: path))
            } else {
                // The daemon prunes folder links only; project Codex ownership uses the same classifier.
                XCTAssertEqual(try ownership.link(at: path, skillsDirectory: skills, linksFile: true), .owned)
                try files.deleteFile(at: path)
            }
        }
    }

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
            removeRegisteredProject(
                project,
                reconciler: CategoryReconciler(platformVM: harness.vm), manifestRoot: TestPaths.storeRoot,
                platformVM: harness.vm,
                localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: preview,
                context: harness.context
            )
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
            let result = removeRegisteredProject(
                project,
                reconciler: CategoryReconciler(platformVM: harness.vm), manifestRoot: TestPaths.storeRoot,
                platformVM: harness.vm,
                localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: plan.preview,
                context: harness.context
            )
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
                targetPath: TestPaths.deployPaths.cursorPath(directoryName: invalidSlug, projectPath: project.path),
                contentHash: "invalid", projectID: project.id))
            try harness.context.save()
            let plan = try ProjectRemovalPlan.prepare(project: project, platformVM: harness.vm, context: harness.context)
            XCTAssertEqual(plan.preview.artifactCount, 2, invalidSlug)
            XCTAssertEqual(Set(plan.candidates.map(\.path)), Set(validPaths), invalidSlug)
            let result = removeRegisteredProject(
                project,
                reconciler: CategoryReconciler(platformVM: harness.vm), manifestRoot: TestPaths.storeRoot,
                platformVM: harness.vm,
                localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: plan.preview,
                context: harness.context
            )
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
                try mapped.createSymlink(at: renamedPath, pointingTo: TestPaths.skillsDir + "/renamed/SKILL.md")
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
            let result = removeRegisteredProject(
                project,
                reconciler: CategoryReconciler(platformVM: harness.vm), manifestRoot: TestPaths.storeRoot,
                platformVM: harness.vm,
                localMachineID: ProjectIntentHarness.localID,
                confirmedPreview: plan.preview,
                context: harness.context
            )
            XCTAssertFalse(result.hasFailures)
            XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
            if platform == .cursor {
                XCTAssertEqual(try mapped.readFile(at: renamedPath), renamedBytes)
            } else {
                XCTAssertEqual(try mapped.symlinkTarget(at: renamedPath), TestPaths.skillsDir + "/renamed/SKILL.md")
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
