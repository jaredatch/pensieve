import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testLeadingCombiningMarksAndNULAreRejectedAtArtifactBoundaries() throws {
        let invalid = ["\u{0301}accent", "\u{0903}spacing", "\u{20dd}enclosing", "bad\0name", "\0name", "name\0"]
        for name in invalid {
            skill = Skill(name: "Invalid", directoryName: name)
            let links = LinkService(fileService: mapped)
            assertInvalidComponent(name) { try LinkService.validatePathComponent(name) }
            try assertInvalidRemovalRoutes(name)
            // Any missed guard fails before reaching a real invalid filesystem path.
            mapped.beforeProjectProbe = { _ in throw CocoaError(.fileReadUnknown) }
            mapped.beforeEntryTypeProbe = { _ in throw CocoaError(.fileReadUnknown) }
            defer { mapped.beforeProjectProbe = nil; mapped.beforeEntryTypeProbe = nil }
            for platform in PlatformTarget.allCases {
                let scopes: [String?] = platform.supportsProjectScope ? [nil, root + "/project"] : [nil]
                for project in scopes {
                    if platform.usesSymlinks {
                        // The scripted boundary supplies an existing target without disk access.
                        let boundary = LinkService(fileService: LinkServiceScriptedFileService(
                            linkPath: links.linkPath(skill: skill, platform: platform, projectPath: project),
                            canonicalDirectory: links.targetPath(skill: skill, platform: platform, projectPath: project),
                            state: .validDirectorySymlink))
                        assertInvalidComponent(name) {
                            try boundary.link(skill: self.skill, platform: platform, projectPath: project)
                        }
                        assertInvalidComponent(name) {
                            _ = try boundary.unlink(skill: self.skill, platform: platform, projectPath: project)
                        }
                        assertInvalidComponent(name) {
                            _ = try boundary.ownsArtifact(skill: self.skill, platform: platform, projectPath: project)
                        }
                    } else {
                        assertInvalidComponent(name) { try self.compiler.compile(skill: self.skill, projectPath: project) }
                        assertInvalidComponent(name) { _ = try self.compiler.remove(skill: self.skill, projectPath: project) }
                        assertInvalidComponent(name) {
                            _ = try self.compiler.ownsArtifact(skill: self.skill, projectPath: project)
                        }
                        assertInvalidComponent(name) {
                            _ = try self.compiler.hasOwnershipMark(skill: self.skill, projectPath: project)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func assertInvalidRemovalRoutes(_ name: String) throws {
        // Saving a NUL-bearing Core Data string truncates it; inject the raw slug after setup.
        skill.directoryName = "owned"
        let harness = try contextAndVM()
        skill.directoryName = name
        let project = reviewProject(harness.context)
        var probes: [String] = []
        mapped.beforeEntryTypeProbe = { probes.append($0); throw CocoaError(.fileReadUnknown) }
        mapped.beforeDeployStateRead = { probes.append($0); throw CocoaError(.fileReadUnknown) }
        defer { mapped.beforeEntryTypeProbe = nil; mapped.beforeDeployStateRead = nil }
        for target: DeployTarget in [.userWide, .project(project)] {
            let platforms = PlatformTarget.allCases.filter { target.project == nil || $0.supportsProjectScope }
            let result = harness.vm.removeOwnedBatch(
                pairs: DeployRemovalPair.expand(skills: [skill], platforms: platforms), target: target)
            XCTAssertEqual(result.failureCount, platforms.count, name.debugDescription)
        }
        let cleanup = harness.vm.removeAllDeploys(skill: skill, projects: [project], localDeployHistory: { _ in
            XCTFail("Invalid slugs must not query history"); return []
        })
        XCTAssertEqual(cleanup.batch.failureCount, 1, name.debugDescription)
        harness.context.insert(SkillProjectAssignment(skillID: skill.id, projectID: project.id, platform: .claudeCode))
        assertInvalidComponent(name) {
            _ = try ProjectRemovalPlan.prepare(project: project, platformVM: harness.vm, context: harness.context)
        }
        XCTAssertTrue(probes.isEmpty, "Reject \(name.debugDescription) before state or artifact I/O")
    }

    private func assertInvalidComponent(_ name: String, operation: () throws -> Void,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case LinkError.invalidPathComponent(let rejected) = error else {
                return XCTFail("Expected component rejection for \(name.debugDescription), got \(error)", file: file, line: line)
            }
            XCTAssertEqual(rejected, name, file: file, line: line)
        }
    }

    func testCanonicalEquivalentSkillTargetsAreOwnedRealizedHealedAndRemoved() throws {
        try useOwnershipSkill(named: "caf\u{00e9}")
        let links = LinkService(fileService: mapped)
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
                    (Constants.pensieveSkillsDir + "/caf\u{00e9}-old"
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
            pensieveSkillsDir: skills, agentSkillDirs: [agents], cursorRulesDir: root + "/canonical-rules")
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
