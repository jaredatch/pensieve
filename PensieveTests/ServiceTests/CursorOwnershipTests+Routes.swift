import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func contextAndVM() throws -> OwnershipRouteHarness {
        let context = ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        skill = Skill(name: "Owned", skillDescription: "Description", directoryName: skill.directoryName)
        context.insert(skill)
        try context.save()
        let state = DeployStateStore(fileService: mapped, appSupportDir: root + "/support")
        let vm = PlatformViewModel(fileService: mapped, cursorCompiler: compiler,
            agentDetection: DeployStubDetection(installed: PlatformTarget.allCases), deployStateStore: state)
        return OwnershipRouteHarness(context: context, vm: vm, state: state)
    }

    @MainActor
    func testAllRemovalRoutesPreserveForeignAndRemoveOwnedArtifacts() throws {
        var cases = 0
        for route in ["single", "bulk", "category", "intent", "skill"] {
            for platform in [PlatformTarget.claudeCode, .grok, .codex, .cursor, .openClaw, .hermes] {
                let scopes: [String?] = platform.supportsProjectScope && route != "category"
                    ? [nil, root + "/project"] : [route == "category" ? root + "/project" : nil]
                if route == "category" && !platform.supportsProjectScope { continue }
                for projectPath in scopes {
                    for owned in [false, true] {
                        for legacy in platform == .cursor && owned ? [false, true] : [false] {
                            let harness = try contextAndVM()
                            let context = harness.context, vm = harness.vm
                            let project = Project(name: "Project", path: root + "/project")
                            project.identityKey = "github.com/owner/project"
                            context.insert(project)
                            let target: DeployTarget = projectPath == nil ? .userWide : .project(project)
                            let path = artifactPath(platform, project: projectPath)
                            try plant(owned: owned, legacy: legacy, platform: platform, path: path, project: projectPath)
                            if route == "skill", platform == .cursor, projectPath != nil, owned {
                                try reviewRecord(harness.state, path: path, target: target)
                            }
                            XCTAssertEqual(try vm.artifactIsOwned(skill: skill, platform: platform, target: target), owned)
                            try removeByRoute(route, harness: harness, platform: platform, project: project, target: target)
                            try verifyRemoval(owned: owned, platform: platform, path: path)
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 97)
    }

    @MainActor
    private func removeByRoute(_ route: String, harness: OwnershipRouteHarness, platform: PlatformTarget,
                               project: Project, target: DeployTarget) throws {
        let context = harness.context, vm = harness.vm
        switch route {
        case "single":
            vm.remove(skill: skill, platform: platform, target: target)
            XCTAssertNil(vm.error)
        case "bulk":
            XCTAssertFalse(vm.removeBatch(
                pairs: DeployRemovalPair.expand(skills: [skill], platforms: [platform]),
                target: target).hasFailures)
        case "category":
            context.insert(SkillProjectAssignment(skillID: skill.id, projectID: project.id, platform: platform))
            try context.save()
            XCTAssertFalse(CategoryReconciler(platformVM: vm).reconcile(context: context).hasFailures)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        case "intent":
            context.insert(IntentAssignment(skillID: skill.id, platformRaw: platform.rawValue, projectID: target.project?.id))
            try context.save()
            XCTAssertFalse(IntentReconciler(platformVM: vm,
                machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
                handoverIsComplete: { true }).reconcile(context: context).hasFailures)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        default:
            let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
                manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
            XCTAssertTrue(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: vm,
                                                  projects: [project], context: context))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Skill>()), 0)
            try files.writeFile(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md", content: "# Body")
        }
    }

    private func verifyRemoval(owned: Bool, platform: PlatformTarget, path: String) throws {
        if owned { XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path)) } else if platform.usesSymlinks {
            XCTAssertEqual(try mapped.symlinkTarget(at: path), root + "/foreign")
        } else {
            XCTAssertEqual(try mapped.readFile(at: path), "User rule")
        }
        if try mapped.entryExistsWithoutFollowingLinks(at: path) { try mapped.deleteFile(at: path) }
    }

    @MainActor
    func testFreshConvergenceRefusesForeignWithoutLedgerOrHistory() throws {
        var cases = 0
        for category in [false, true] {
            let platforms = category ? PlatformTarget.allCases.filter(\.supportsProjectScope) : PlatformTarget.allCases
            for platform in platforms {
                let scopes: [String?] = category ? [root + "/project"]
                    : platform.supportsProjectScope ? [nil, root + "/project"] : [nil]
                for projectPath in scopes {
                    try verifyFreshCollision(category: category, platform: platform, projectPath: projectPath)
                    cases += 1
                }
            }
        }
        XCTAssertEqual(cases, 14)
    }

    @MainActor
    private func verifyFreshCollision(category: Bool, platform: PlatformTarget, projectPath: String?) throws {
        let harness = try contextAndVM()
        let context = harness.context, vm = harness.vm
        let project = Project(name: "Project", path: root + "/project")
        project.identityKey = "github.com/owner/project"
        context.insert(project)
        let path = artifactPath(platform, project: projectPath)
        try plant(owned: false, legacy: false, platform: platform, path: path, project: projectPath)
        if category {
            let rule = Pensieve.Category(name: "Rule")
            rule.skillSlugs = [skill.directoryName]
            rule.projectKeys = [project.identityKey!]
            context.insert(rule)
        } else {
            context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID, skillSlug: skill.directoryName,
                platformRaw: platform.rawValue, projectKey: projectPath == nil ? nil : project.identityKey))
        }
        try context.save()
        let result = category ? CategoryReconciler(platformVM: vm).reconcile(context: context)
            : IntentReconciler(platformVM: vm,
                               machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
                               handoverIsComplete: { true }).reconcile(context: context)
        // Category wants all installed project agents; only the colliding pair fails.
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertTrue(result.failures.first?.error?.contains(path) == true)
        let categoryRows = try context.fetch(FetchDescriptor<SkillProjectAssignment>())
        XCTAssertFalse(categoryRows.contains { $0.platform == platform })
        let intentRows = try context.fetch(FetchDescriptor<IntentAssignment>())
        XCTAssertFalse(intentRows.contains { $0.platformRaw == platform.rawValue })
        XCTAssertFalse(try context.fetch(FetchDescriptor<DeployRecord>()).contains { $0.platform == platform })
        if platform.usesSymlinks {
            XCTAssertEqual(try mapped.symlinkTarget(at: path), root + "/foreign")
        } else {
            XCTAssertEqual(try mapped.readFile(at: path), "User rule")
        }
        _ = vm.removeAllDeploys(skill: skill, projects: [project], localDeployHistory: { _ in [] }).batch
        try mapped.deleteFile(at: path)
    }

    @MainActor
    func testUserWideIntentRetriesForeignAndHealsOwnedWithoutDuplicateLedger() throws {
        for platform in PlatformTarget.allCases.filter(\.usesSymlinks) {
            let harness = try contextAndVM()
            let context = harness.context, vm = harness.vm
            context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID,
                skillSlug: skill.directoryName, platformRaw: platform.rawValue))
            try context.save()
            let reconciler = IntentReconciler(platformVM: vm,
                machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
                handoverIsComplete: { true })
            XCTAssertEqual(reconciler.reconcile(context: context).successes.count, 1)
            let path = artifactPath(platform, project: nil)
            try plant(owned: false, legacy: false, platform: platform, path: path, project: nil)
            XCTAssertEqual(reconciler.reconcile(context: context).failureCount, 1)
            XCTAssertEqual(try mapped.symlinkTarget(at: path), root + "/foreign")
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DeployRecord>()), 1)
            try plant(owned: true, legacy: false, platform: platform, path: path, project: nil)
            XCTAssertEqual(reconciler.reconcile(context: context).successes.count, 1)
            XCTAssertEqual(try mapped.symlinkTarget(at: path), Constants.pensieveSkillsDir + "/" + skill.directoryName)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DeployRecord>()), 2)
            XCTAssertTrue(reconciler.reconcile(context: context).outcomes.isEmpty)
            _ = vm.removeAllDeploys(skill: skill, projects: [], localDeployHistory: { _ in [] }).batch
        }
    }

    @MainActor
    func testHistoryAndDeployStateCannotAdoptDifferentLegacyBytes() throws {
        let harness = try contextAndVM()
        let context = harness.context, vm = harness.vm, state = harness.state
        let path = compiler.outputPath(skill: skill, projectPath: nil)
        let content = "---\ndescription: Description\nalwaysApply: false\n---\n\n# Bodx\n"
        try mapped.writeFile(at: path, content: content)
        context.insert(DeployRecord(skillID: skill.id, platform: .cursor, targetPath: path, contentHash: "old"))
        try context.save()
        try state.upsert(DeployStateRecord(slug: skill.directoryName, platform: "cursor", scope: "user",
            projectIdentityKey: nil, artifactPath: path, recordedAt: "2026-10-05T00:00:00Z"))
        vm.deploy(skill: skill, platform: .cursor, context: context)
        XCTAssertTrue(vm.error?.contains(path) == true)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DeployRecord>()), 1)
        vm.remove(skill: skill, platform: .cursor)
        XCTAssertNil(vm.error)
        XCTAssertEqual(try mapped.readFile(at: path), content)
        XCTAssertTrue(try state.read().records.isEmpty)
    }

    func artifactPath(_ platform: PlatformTarget, project: String?) -> String {
        platform.usesSymlinks
            ? DeployPaths.linkPath(directoryName: skill.directoryName, platform: platform, projectPath: project)
            : compiler.outputPath(skill: skill, projectPath: project)
    }

    func plant(owned: Bool, legacy: Bool, platform: PlatformTarget, path: String, project: String?) throws {
        if try mapped.entryExistsWithoutFollowingLinks(at: path) { try mapped.deleteFile(at: path) }
        if platform.usesSymlinks {
            let target = owned
                ? Constants.pensieveSkillsDir + "/other" + (platform == .codex && project != nil ? "/SKILL.md" : "")
                : root + "/foreign"
            try mapped.createSymlink(at: path, pointingTo: target)
        } else {
            let text = !owned ? "User rule" : legacy
                ? "---\ndescription: Description\nalwaysApply: false\n---\n\n# Body\n"
                : "---\n# pensieve: managed\n---\nStale"
            try mapped.writeFile(at: path, content: text)
        }
    }
}

struct OwnershipRouteHarness {
    let context: ModelContext
    let vm: PlatformViewModel
    let state: DeployStateStore
}
