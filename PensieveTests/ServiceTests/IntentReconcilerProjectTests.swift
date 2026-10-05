import Foundation
import SwiftData
import XCTest
@testable import Pensieve

private struct PendingProjectIntent {
    let slug: String
    let platformRaw: String
    let projectKey: String
}

private func makeLaunchManifest(
    root: String,
    fileService: FileService,
    slug: String
) throws -> ManifestService {
    let manifest = ManifestService(fileService: fileService)
    try fileService.writeFile(
        at: root + "/skills/" + slug + "/SKILL.md",
        content: SkillSerializer.serialize(name: slug, description: "launch", body: "body")
    )
    try manifest.write(
        ManifestSnapshot(
            schemaVersion: 5,
            categories: [],

            projects: [],
            skills: [SkillOverlay(
                slug: slug,
                createdAt: Date(timeIntervalSince1970: 1),
                scope: .user,
                tags: [],
                cursor: nil,
                agents: [],
                origin: .authored
            )],
            deployIntents: [DeployIntentRecord(
                machineID: ProjectIntentHarness.localID,
                skillSlug: slug,
                platformRaw: PlatformTarget.codex.rawValue,
                projectKey: "launch-key"
            )]
        ),
        toRoot: root
    )
    return manifest
}

@MainActor
final class IntentReconcilerProjectTests: XCTestCase {
    func testProjectIntentFansOutToMatchingCheckoutsAndIsIdempotent() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("fanout")
        let first = try harness.insertProject(name: "First", path: "/projects/first", key: "shared-key")
        let second = try harness.insertProject(name: "Second", path: "/projects/second", key: "shared-key")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "shared-key")
        _ = try harness.insertIntent(
            skill: skill, platformRaw: "codex", projectKey: "shared-key",
            machineID: ProjectIntentHarness.remoteID
        )

        let firstResult = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(firstResult.hasFailures)
        XCTAssertEqual(Set(harness.linkService.linkCalls.map(\.projectPath)), Set([first.path, second.path]))
        XCTAssertEqual(Set(try harness.assignments().compactMap(\.projectID)), Set([first.id, second.id]))

        harness.linkService.linkCalls.removeAll()
        let secondResult = harness.reconciler.reconcile(context: harness.context)
        XCTAssertTrue(secondResult.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertEqual(try harness.assignments().count, 2)
    }

    func testRemoteMachineProjectIntentDoesNotApplyLocally() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("remote-only")
        _ = try harness.insertProject(name: "Local", path: "/projects/local", key: "shared-key")
        _ = try harness.insertIntent(
            skill: skill,
            platformRaw: "codex",
            projectKey: "shared-key",
            machineID: ProjectIntentHarness.remoteID
        )

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(try harness.assignments().isEmpty)
        XCTAssertTrue(harness.fileService.symlinks.isEmpty)
    }

    func testProjectIntentPendingCasesLeaveIntentRowsUntouched() throws {
        let harness = try ProjectIntentHarness(installed: [.codex, .openClaw, .hermes])
        let skill = try harness.insertSkill("pending")
        _ = try harness.insertProject(name: "Known", path: "/projects/known", key: "known-key")
        let inputs = [
            PendingProjectIntent(slug: skill.directoryName, platformRaw: "codex", projectKey: "missing-key"),
            PendingProjectIntent(slug: skill.directoryName, platformRaw: "cursor", projectKey: "known-key"),
            PendingProjectIntent(slug: skill.directoryName, platformRaw: "openClaw", projectKey: "known-key"),
            PendingProjectIntent(slug: skill.directoryName, platformRaw: "hermes", projectKey: "known-key"),
            PendingProjectIntent(slug: skill.directoryName, platformRaw: "futureAgent", projectKey: "known-key"),
            PendingProjectIntent(slug: "missing-skill", platformRaw: "codex", projectKey: "known-key")
        ]
        for input in inputs {
            harness.context.insert(MachineDeployIntent(
                machineID: ProjectIntentHarness.localID,
                skillSlug: input.slug,
                platformRaw: input.platformRaw,
                projectKey: input.projectKey
            ))
        }
        try harness.context.save()
        let keysBefore = try harness.intents().map(\.key).sorted()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(try harness.assignments().isEmpty)
        XCTAssertEqual(try harness.intents().map(\.key).sorted(), keysBefore)
    }

    func testRegistrationAppliesPendingProjectIntentImmediately() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("register")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "register-key")
        XCTAssertTrue(harness.reconciler.reconcile(context: harness.context).outcomes.isEmpty)

        let project = Project(name: "Registered", path: "/projects/registered")
        harness.fileService.directories.insert(project.path)
        project.identityKey = "register-key"
        registerProject(
            project,
            context: harness.context,
            intentReconciler: harness.reconciler.reconcile
        )

        XCTAssertEqual(harness.linkService.linkCalls.map(\.projectPath), [project.path])
        XCTAssertEqual(try harness.assignments().map(\.projectID), [project.id])
    }

    func testLaunchIngestAppliesIntentAfterPlatformIsInstalled() throws {
        let harness = try ProjectIntentHarness(installed: [])
        let project = try harness.insertProject(
            name: "Launch Project", path: "/projects/launch", key: "launch-key"
        )
        let root = NSTemporaryDirectory() + "PensieveLaunchProjectApply-" + UUID().uuidString
        let fileService = FileService()
        defer { try? fileService.deleteDirectory(at: root) }
        let slug = "launch-apply"
        let manifest = try makeLaunchManifest(root: root, fileService: fileService, slug: slug)

        let rebuild = StoreRebuildService(fileService: fileService, manifestService: manifest)
            .rebuild(fromRoot: root, context: harness.context)
        let pendingResult = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(pendingResult.hasFailures)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(try harness.assignments().isEmpty)

        let installedVM = harness.makePlatformVM(installed: [.codex])
        let launchReconciler = IntentReconciler(
            platformVM: installedVM,
            machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID), handoverIsComplete: { false }
        )
        let result = launchReconciler.reconcile(context: harness.context)

        XCTAssertFalse(rebuild.storeUnreadable)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.linkCalls, [
            DeployRecordedLink(directoryName: slug, platform: .codex, projectPath: project.path)
        ])
        XCTAssertEqual(try harness.assignments().map(\.projectID), [project.id])
    }

    func testSecondViewModelSeesAndRemovesFirstPassDeployState() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("shared-state")
        let project = try harness.insertProject(name: "Shared", path: "/projects/shared", key: "shared-key")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "shared-key")
        XCTAssertEqual(harness.reconciler.reconcile(context: harness.context).successes.count, 1)
        let records = harness.platformVM.deployIndex.records(for: skill.directoryName)
        XCTAssertEqual(records.map(\.artifactPath), [harness.artifactPath(skill: skill, platform: .codex, project: project)])

        let installedVM = harness.makePlatformVM(installed: [.codex])
        XCTAssertEqual(installedVM.deployIndex.records(for: skill.directoryName), records,
                       "The later view model reads the first pass's isolated deploy state")
        XCTAssertFalse(installedVM.removeBatch(skills: [skill], platforms: [.codex], target: .project(project)).hasFailures)
        harness.platformVM.refreshDeployIndex()
        XCTAssertTrue(harness.platformVM.deployIndex.records(for: skill.directoryName).isEmpty,
                      "A removal by the later view model updates the same store")
    }

    func testProjectRetractionTouchesOnlyItsExactTuple() throws {
        let harness = try ProjectIntentHarness(installed: [.codex, .claudeCode])
        let skill = try harness.insertSkill("isolation")
        let first = try harness.insertProject(name: "First", path: "/projects/first", key: "first-key")
        let second = try harness.insertProject(name: "Second", path: "/projects/second", key: "second-key")
        let removed = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "first-key")
        _ = try harness.insertIntent(skill: skill, platformRaw: "claudeCode", projectKey: "first-key")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "second-key")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex")
        _ = harness.reconciler.reconcile(context: harness.context)
        harness.context.delete(removed)
        try harness.context.save()
        harness.linkService.unlinkCalls.removeAll()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.unlinkCalls, [
            DeployRecordedLink(directoryName: skill.directoryName, platform: .codex, projectPath: first.path)
        ])
        let livePaths = harness.fileService.symlinks
        XCTAssertFalse(livePaths.contains(harness.artifactPath(skill: skill, platform: .codex, project: first)))
        XCTAssertTrue(livePaths.contains(harness.artifactPath(skill: skill, platform: .claudeCode, project: first)))
        XCTAssertTrue(livePaths.contains(harness.artifactPath(skill: skill, platform: .codex, project: second)))
        XCTAssertTrue(livePaths.contains(harness.artifactPath(skill: skill, platform: .codex, project: nil)))
        XCTAssertEqual(try harness.assignments().count, 3)
    }

    func testManualProjectDeploySurvivesIntentReconcile() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("manual-project")
        let project = try harness.insertProject(name: "Manual", path: "/projects/manual", key: "manual-key")
        harness.platformVM.deploy(
            skill: skill, platform: .codex, target: .project(project), context: harness.context
        )
        harness.linkService.unlinkCalls.removeAll()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: project)
        ))
        XCTAssertTrue(try harness.assignments().isEmpty)
    }

    func testManualProjectDeploySurvivesWhileAnotherProjectsIntentIsRealized() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("manual-with-intent")
        let manualProject = try harness.insertProject(
            name: "Manual", path: "/projects/manual-with-intent", key: "manual-key"
        )
        let intendedProject = try harness.insertProject(
            name: "Intended", path: "/projects/intended", key: "intended-key"
        )
        harness.platformVM.deploy(
            skill: skill, platform: .codex, target: .project(manualProject), context: harness.context
        )
        _ = try harness.insertIntent(
            skill: skill, platformRaw: "codex", projectKey: "intended-key"
        )
        harness.linkService.linkCalls.removeAll()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.linkCalls.map(\.projectPath), [intendedProject.path])
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: manualProject)
        ))
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: intendedProject)
        ))
        XCTAssertEqual(try harness.assignments().map(\.projectID), [intendedProject.id])
    }

    func testMissingMachineIDChangesNothingAtEitherScope() throws {
        let harness = try ProjectIntentHarness(installed: [.codex], identityFails: true)
        let skill = try harness.insertSkill("no-machine")
        let project = try harness.insertProject(name: "Project", path: "/projects/no-machine", key: "key")
        harness.platformVM.deploy(skill: skill, platform: .codex, target: .userWide, context: harness.context)
        harness.platformVM.deploy(skill: skill, platform: .codex, target: .project(project), context: harness.context)
        harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "codex"))
        harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "codex", projectID: project.id))
        try harness.context.save()
        harness.linkService.unlinkCalls.removeAll()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertEqual(try harness.assignments().count, 2)
        XCTAssertEqual(harness.fileService.symlinks.count, 2)
    }

    func testUserWideBehaviorIsUnchangedBesideProjectRows() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let desired = try harness.insertSkill("desired-user")
        let removed = try harness.insertSkill("removed-user")
        let projectSkill = try harness.insertSkill("project-row")
        let project = try harness.insertProject(name: "Project", path: "/projects/mixed", key: "mixed-key")
        _ = try harness.insertIntent(skill: desired, platformRaw: "codex")
        _ = try harness.insertIntent(skill: projectSkill, platformRaw: "codex", projectKey: "mixed-key")
        harness.platformVM.deploy(skill: removed, platform: .codex, target: .userWide, context: harness.context)
        harness.platformVM.deploy(skill: projectSkill, platform: .codex, target: .project(project), context: harness.context)
        harness.context.insert(IntentAssignment(skillID: removed.id, platformRaw: "codex"))
        harness.context.insert(IntentAssignment(
            skillID: projectSkill.id, platformRaw: "codex", projectID: project.id
        ))
        try harness.context.save()
        harness.linkService.linkCalls.removeAll()
        harness.linkService.unlinkCalls.removeAll()

        let result = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(harness.linkService.linkCalls.map(\.directoryName), [desired.directoryName])
        XCTAssertEqual(harness.linkService.unlinkCalls.map(\.directoryName), [removed.directoryName])
        XCTAssertEqual(try harness.assignments().filter { $0.projectID == project.id }.count, 1)
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: projectSkill, platform: .codex, project: project)
        ))
    }
}
