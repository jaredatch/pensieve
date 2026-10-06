import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testConvergenceMarksLedgeredLegacyBeforeSourceChanges() throws {
        for category in [false, true] {
            for projectScope in category ? [true] : [false, true] {
                let harness = try contextAndVM()
                let context = harness.context
                let project = reviewProject(context)
                let path = artifactPath(.cursor, project: projectScope ? project.path : nil)
                try store.writeBody(directoryName: skill.directoryName, body: "# Body")
                try plant(owned: true, legacy: true, platform: .cursor, path: path, project: projectScope ? project.path : nil)
                let rule = Pensieve.Category(name: "Review")
                let intent = MachineDeployIntent(machineID: ProjectIntentHarness.localID, skillSlug: skill.directoryName,
                    platformRaw: "cursor", projectKey: projectScope ? project.identityKey : nil)
                if category {
                    rule.skillSlugs = [skill.directoryName]
                    rule.projectKeys = [project.identityKey!]
                    context.insert(rule)
                    context.insert(SkillProjectAssignment(skillID: skill.id, projectID: project.id, platform: .cursor))
                } else {
                    context.insert(intent)
                    context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor",
                        projectID: projectScope ? project.id : nil))
                }
                try context.save()
                let converge = { category ? CategoryReconciler(platformVM: harness.vm).reconcile(context: context)
                    : self.reviewIntent(harness.vm).reconcile(context: context) }
                XCTAssertFalse(converge().hasFailures)
                XCTAssertTrue(try mapped.readFile(at: path).contains("# pensieve: managed"))
                skill.skillDescription = "Changed description"
                skill.cursorConfig = CursorAdapterConfig(description: "Configured", globs: ["*.swift"], alwaysApply: true)
                try store.writeBody(directoryName: skill.directoryName, body: "# Changed")
                if category { context.delete(rule) } else { context.delete(intent) }
                try context.save()
                XCTAssertFalse(converge().hasFailures)
                XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
                skill.cursorConfig = nil
            }
        }
    }

    @MainActor
    func testUnselectReportsUnreadableUnledgeredRule() throws {
        for projectScope in [false, true] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let target: DeployTarget = projectScope ? .project(project) : .userWide
            let path = artifactPath(.cursor, project: target.project?.path)
            let text = "---\n# pensieve: managed\n---\nKeep"
            try mapped.writeFile(at: path, content: text)
            let physical = projectScope ? path : root + "/user/rules/" + skill.directoryName + ".mdc"
            XCTAssertEqual(chmod(physical, 0o000), 0)
            defer { XCTAssertEqual(chmod(physical, 0o600), 0) }
            let intent = reviewIntent(harness.vm)
            let manifest = ManifestService(fileService: files)
            let model = DeployIntentModel(platformVM: harness.vm, dependencies: DeployIntentDependencies(
                identity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
                stateService: MachineStateService(fileService: mapped), root: root + "/store",
                writeManifest: { try manifest.write(try manifest.snapshot(from: $0), toRoot: self.root + "/store") },
                notifier: {}, reconcile: { intent.reconcile(context: $0) }, lockPath: root + "/support/intent.lock"))
            let result = try model.set(false, skill: skill, platform: .cursor, target: target, context: harness.context)
            XCTAssertEqual(result.failureCount, 1)
            XCTAssertTrue(result.failures.first?.error?.contains("Could not check ownership") == true)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertEqual(chmod(physical, 0o600), 0)
            XCTAssertEqual(try mapped.readFile(at: path), text)
        }
    }

    @MainActor
    func testIntentRemovalRetiresForeignArtifactStateInBothScopes() throws {
        for projectScope in [false, true] {
            for platform in [PlatformTarget.claudeCode, .cursor] {
                let harness = try contextAndVM()
                let project = reviewProject(harness.context)
                let target: DeployTarget = projectScope ? .project(project) : .userWide
                let path = artifactPath(platform, project: target.project?.path)
                try plant(owned: false, legacy: false, platform: platform, path: path, project: target.project?.path)
                try reviewRecord(harness.state, path: path, platform: platform, target: target)
                harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: platform.rawValue,
                    projectID: target.project?.id))
                try harness.context.save()
                XCTAssertFalse(reviewIntent(harness.vm).reconcile(context: harness.context).hasFailures)
                XCTAssertTrue(try harness.state.read().records.isEmpty)
                XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
                if platform.usesSymlinks {
                    XCTAssertEqual(try mapped.symlinkTarget(at: path), root + "/foreign")
                } else {
                    XCTAssertEqual(try mapped.readFile(at: path), "User rule")
                }
                try mapped.deleteFile(at: path)
            }
        }
    }

    @MainActor
    func testIntentOwnershipFailuresUseBatchPresentationAndRetainState() throws {
        for projectScope in [false, true] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let target: DeployTarget = projectScope ? .project(project) : .userWide
            let path = artifactPath(.cursor, project: target.project?.path)
            let text = "---\n# pensieve: managed\n---\nKeep"
            try mapped.writeFile(at: path, content: text)
            try reviewRecord(harness.state, path: path, target: target)
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor", projectID: target.project?.id))
            try harness.context.save()
            let readError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            mapped.beforeRuleRead = { _ in throw readError }
            let result = reviewIntent(harness.vm).reconcile(context: harness.context)
            let ownershipError = ArtifactOwnershipError.couldNotCheck(path: path, reason: readError.localizedDescription)
            XCTAssertEqual(result.failures.first?.error, BatchPairOutcome.failureMessage(ownershipError, target: target))
            XCTAssertEqual(result.failureCount, 1)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
            XCTAssertTrue(try harness.state.read().records.contains { $0.artifactPath == path })
            mapped.beforeRuleRead = nil
            XCTAssertEqual(try mapped.readFile(at: path), text)
        }
    }

    @MainActor
    func reviewProject(_ context: ModelContext) -> Project {
        let project = Project(name: "Review Project", path: root + "/project")
        project.identityKey = "github.com/owner/project"
        context.insert(project)
        return project
    }

    func reviewIntent(_ vm: PlatformViewModel) -> IntentReconciler {
        IntentReconciler(platformVM: vm, machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
                         handoverIsComplete: { true })
    }

    func reviewRecord(_ state: DeployStateStore, path: String, platform: PlatformTarget = .cursor,
                      target: DeployTarget) throws {
        try state.upsert(DeployStateRecord(slug: skill.directoryName, platform: platform.rawValue,
            scope: target.project == nil ? "user" : "project", projectIdentityKey: target.project?.identityKey,
            artifactPath: path, recordedAt: "2026-10-05T00:00:00Z"))
    }
}
