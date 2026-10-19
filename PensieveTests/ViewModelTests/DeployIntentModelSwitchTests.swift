import SwiftData
import XCTest
@testable import Pensieve

private struct UnreadableSwitchIdentity: MachineIdentityProviding {
    func identifier() throws -> String { throw DeployStubFailure() }
}

@MainActor
extension DeployIntentModelTests {
    func testSelectionReturnsAppliedResultAndLeavesTheCatalogToTheNextReload() throws {
        for target in [localID, remoteID] {
            let identity = ReloadFailingIdentity(id: localID)
            var failWrite = false
            let harness = try makeHarness(saveContext: { context in
                if failWrite { throw DeployStubFailure() }
                try context.save()
            }, identity: identity, onReconcile: { identity.fails = true })
            let skill = try insertSkill(context: harness.context)
            harness.model.reload(context: harness.context)
            let machines = harness.model.machines
            for selected in [true, false] {
                identity.fails = false
                var result: BatchResult?
                XCTAssertNoThrow(result = try harness.model.setSelected(
                    selected, machineID: target, skill: skill, platform: .codex, context: harness.context
                ))
                XCTAssertNil(harness.model.error, "An applied change is no error, and no refresh runs inside it")
                if target == localID {
                    XCTAssertEqual(result?.successes.count, 1)
                    XCTAssertEqual(harness.platformVM.isDeployed(skill: skill, platform: .codex), selected)
                } else {
                    XCTAssertNil(result, "Remote-only changes still return no local result")
                    XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
                    XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
                }
                let manifest = try ManifestService(fileService: harness.manifestFileService).read(fromRoot: harness.root)
                XCTAssertEqual(manifest.deployIntents.count, selected ? 1 : 0)
                XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), selected ? 1 : 0)
                XCTAssertEqual(harness.model.machines, machines, "The catalog is left to the next reload")
                if selected {
                    identity.fails = false
                    failWrite = true
                    XCTAssertThrowsError(try harness.model.setSelected(
                        false, machineID: target, skill: skill, platform: .codex, context: harness.context
                    ))
                    XCTAssertEqual(harness.model.error, DeployStubFailure().localizedDescription)
                    failWrite = false
                }
            }
            identity.fails = false
            harness.model.reload(context: harness.context)
            XCTAssertNil(harness.model.error, "The next reload clears the failed write's error")
        }
    }

    func testPlainReloadFailureRemainsAnErrorAndKeepsTheCatalog() throws {
        let identity = ReloadFailingIdentity(id: localID)
        let harness = try makeHarness(identity: identity)
        harness.model.reload(context: harness.context)
        let machines = harness.model.machines
        let platforms = harness.model.availablePlatforms
        identity.fails = true

        harness.model.reload(context: harness.context)

        XCTAssertEqual(harness.model.error, DeployStubFailure().localizedDescription)
        XCTAssertEqual(harness.model.machines, machines)
        XCTAssertEqual(harness.model.availablePlatforms, platforms)
        identity.fails = false
        harness.model.reload(context: harness.context)
        XCTAssertNil(harness.model.error)
    }

    func testLocalAndProjectSwitchesPersistBeforeDeployAndNudge() async throws {
        var events: [String] = []
        var nudges = 0
        let harness = try makeHarness(
            notifier: { nudges += 1 },
            onWriteManifest: { events.append("manifest") },
            onReconcile: { events.append("reconcile") }
        )
        let skill = try insertSkill(context: harness.context)
        let project = Project(name: "Project", path: "/tmp/project")
        project.identityKey = "github.com/owner/project"
        harness.context.insert(project)
        try harness.context.save()

        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .project(project), context: harness.context
        )

        XCTAssertEqual(events, ["manifest", "reconcile", "manifest", "reconcile"])
        XCTAssertEqual(nudges, 2)
        XCTAssertEqual(harness.linkService.linkCalls.map(\.projectPath), [nil, project.path])
        let rows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(Set(rows.compactMap(\.projectKey)), ["github.com/owner/project"])
        XCTAssertEqual(rows.filter { $0.projectKey == nil }.count, 1)
        let manifest = try ManifestService(fileService: harness.manifestFileService).read(fromRoot: harness.root)
        XCTAssertEqual(manifest.deployIntents.count, 2)
        try await assertRuntimeDeploymentNudges()
    }

    func testTurningOffIntentAndManualDeploysAlwaysRemovesArtifactWithoutAdoption() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )

        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )

        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 1)

        harness.platformVM.deploy(
            skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        harness.model.reload(context: harness.context)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)

        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 2)
    }

    func testManifestWriteFailuresRestoreOnAndOffSwitchState() throws {
        let failedOn = try makeHarness(writeManifest: { _ in throw DeployStubFailure() })
        let failedOnSkill = try insertSkill(context: failedOn.context)

        XCTAssertThrowsError(try failedOn.model.set(
            true, skill: failedOnSkill, platform: .codex,
            target: .userWide, context: failedOn.context
        ))
        XCTAssertEqual(try failedOn.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertTrue(failedOn.linkService.linkCalls.isEmpty)
        XCTAssertNotNil(failedOn.model.error)

        var writes = 0
        let failedOff = try makeHarness(writeManifest: { _ in
            writes += 1
            if writes == 2 { throw DeployStubFailure() }
        })
        let failedOffSkill = try insertSkill(context: failedOff.context)
        _ = try failedOff.model.set(
            true, skill: failedOffSkill, platform: .codex,
            target: .userWide, context: failedOff.context
        )

        XCTAssertThrowsError(try failedOff.model.set(
            false, skill: failedOffSkill, platform: .codex,
            target: .userWide, context: failedOff.context
        ))
        XCTAssertEqual(try failedOff.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertEqual(try failedOff.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
        XCTAssertEqual(failedOff.linkService.unlinkCalls.count, 0)
        XCTAssertNotNil(failedOff.model.error)
    }

    func testUnreadableMachineIDRefusesIntentButKeylessProjectStaysDirect() async throws {
        let harness = try makeHarness(identity: UnreadableSwitchIdentity())
        let skill = try insertSkill(context: harness.context)

        XCTAssertThrowsError(try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        ))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertNotNil(harness.model.error)

        let project = Project(name: "Keyless", path: "/tmp/keyless")
        harness.context.insert(project)
        try harness.context.save()
        let result = try harness.model.set(
            true, skill: skill, platform: .codex, target: .project(project), context: harness.context
        )

        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(harness.linkService.linkCalls.map(\.projectPath), [project.path])
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)

        let cli = await CLIDeployHandler(service: harness.model.service, files: harness.linkService.fileService).handle(
            CLIRequest(command: "deploy", arguments: [skill.directoryName], deployment: CLIDeployOptions(
                agents: ["codex"], project: project.name, workingDirectory: harness.root)), context: harness.context)
        XCTAssertTrue(cli.envelope.ok, "The CLI's keyless local path also needs no machine identity")
        XCTAssertEqual(cli.envelope.changed, false)

        let invalid = Project(name: "Invalid", path: "/tmp/invalid")
        invalid.identityKey = " leading-space"
        harness.context.insert(invalid)
        try harness.context.save()
        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .project(invalid), context: harness.context
        )
        XCTAssertEqual(harness.linkService.linkCalls.map(\.projectPath), [project.path, invalid.path])
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    func testExistingIntentRepairsMissingArtifactWithoutRewritingManifest() throws {
        var nudges = 0
        let harness = try makeHarness(notifier: { nudges += 1 })
        let skill = try insertSkill(context: harness.context)
        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        let path = harness.root + "/manifest/deploys/" + localID + "/alpha.yaml"
        let before = try harness.manifestFileService.readData(at: path)
        let artifact = harness.linkService.linkPath(skill: skill, platform: .codex, projectPath: nil)
        try harness.linkService.fileService.deleteFile(at: artifact)

        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )

        XCTAssertEqual(try harness.manifestFileService.readData(at: path), before)
        XCTAssertEqual(harness.linkService.linkCalls.count, 2)
        XCTAssertEqual(nudges, 1)
    }

    func testUserWideBulkOperationsPreserveProjectRowsAndPlatformChoices() throws {
        let harness = try makeHarness(states: [])
        let skill = try insertSkill(context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: skill.directoryName,
            platformRaw: PlatformTarget.hermes.rawValue, projectKey: "github.com/owner/project"
        ))
        try harness.context.save()

        harness.model.reload(context: harness.context)
        XCTAssertFalse(harness.model.availablePlatforms.contains(.hermes))
        _ = try harness.model.apply(
            skills: [skill], platforms: [.codex], selectedMachineIDs: [localID], context: harness.context
        )
        XCTAssertEqual(try harness.model.selectedMachineIDs(
            skills: [skill], platforms: [.codex], context: harness.context
        ), [localID])
        _ = try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [localID], context: harness.context
        )

        let rows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.projectKey, "github.com/owner/project")
        XCTAssertEqual(rows.first?.platformRaw, PlatformTarget.hermes.rawValue)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 1)
    }

    func testBulkProjectTargetWritesAndRetractsProjectIntents() async throws {
        let harness = try makeHarness()
        let alpha = try insertSkill(context: harness.context)
        let beta = Skill(name: "Beta", directoryName: "beta")
        let project = Project(name: "Project", path: "/tmp/project")
        project.identityKey = "github.com/owner/project"
        harness.linkService.fileService.directories.insert(project.path)
        harness.context.insert(beta)
        harness.context.insert(project)
        try harness.context.save()

        _ = try BulkDeploySheet.perform(
            .deploy, forProject: true, platformVM: harness.platformVM, intentModel: harness.model,
            skills: [alpha, beta], platforms: [.codex], target: .project(project),
            machineIDs: [], context: harness.context
        )

        var rows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(Set(rows.map(\.skillSlug)), ["alpha", "beta"])
        XCTAssertTrue(rows.allSatisfy { $0.machineID == localID && $0.projectKey == project.identityKey })
        XCTAssertEqual(harness.linkService.linkCalls.map(\.projectPath), [project.path, project.path])

        _ = try BulkDeploySheet.perform(
            .remove, forProject: true, platformVM: harness.platformVM, intentModel: harness.model,
            skills: [alpha, beta], platforms: [.codex], target: .project(project),
            machineIDs: [], context: harness.context
        )
        rows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(harness.linkService.unlinkCalls.map(\.projectPath), [project.path, project.path])
        try await assertDeploymentErrorsStayWithTheirWindow()
    }

    func testSwitchRefusesWhileSyncLockIsHeldBeforeChangingAnything() throws {
        let lockPath = TestTemporaryDirectory.path + "PensieveSwitchLock-" + UUID().uuidString + ".lock"
        let harness = try makeHarness(lockPath: lockPath)
        let skill = try insertSkill(context: harness.context)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { lock.release() }

        XCTAssertThrowsError(try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        ))

        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertEqual(harness.model.error, "Sync is running. Try again when it finishes.")
    }

    func testTwoImmediateFlipsEndInSecondState() throws {
        var nudges = 0
        let harness = try makeHarness(notifier: { nudges += 1 })
        let skill = try insertSkill(context: harness.context)

        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )

        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 1)
        XCTAssertEqual(nudges, 2)
    }
}

private final class ReloadFailingIdentity: MachineIdentityProviding {
    let id: String
    var fails = false
    init(id: String) { self.id = id }
    func identifier() throws -> String {
        if fails { throw DeployStubFailure() }
        return id
    }
    func existingIdentifier() throws -> String? { id }
}
