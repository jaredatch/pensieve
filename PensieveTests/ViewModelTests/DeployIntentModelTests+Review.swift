import SwiftData
import XCTest
@testable import Pensieve

struct DeployIntentIdentityStub: MachineIdentityProviding {
    let id: String
    func identifier() throws -> String { id }
}

struct DeployIntentStateStub: MachineStateServicing {
    let states: [MachineState]
    func compose(machineID: String, context: ModelContext, publishedAt: Date) throws -> MachineState {
        throw DeployStubFailure()
    }
    func write(_ state: MachineState, toRoot root: String) throws {}
    func readAll(fromRoot root: String) -> [MachineState] { states }
}

@MainActor
extension DeployIntentModelTests {
    func testPerformRemoveProjectRoutesToBatch() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        let project = Project(name: "Project", path: "/tmp/project")
        harness.context.insert(project)
        harness.linkService.fileService.directories.insert(project.path)
        try harness.linkService.link(skill: skill, platform: .codex, projectPath: project.path)
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: skill.directoryName, platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()

        let outcome = try BulkDeploySheet.perform(
            .remove, forProject: true, platformVM: harness.platformVM, intentModel: harness.model,
            skills: [skill], platforms: [.codex], target: .project(project),
            machineIDs: [remoteID], context: harness.context
        )

        guard case let .localDeploy(batch) = outcome else { return XCTFail("expected project batch removal") }
        XCTAssertEqual(batch.successes.count, 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertEqual(harness.linkService.unlinkCalls.map(\.projectPath), [project.path])
        let noOp = try BulkDeploySheet.perform(
            .remove, forProject: true, platformVM: harness.platformVM, intentModel: harness.model,
            skills: [skill], platforms: [.codex], target: .project(project),
            machineIDs: [remoteID], context: harness.context
        )
        guard case let .localDeploy(empty) = noOp else { return XCTFail("expected project batch removal") }
        XCTAssertTrue(empty.outcomes.isEmpty)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 1)
    }

    func testSheetReadFailureDoesNotDeleteAnyMachineIntent() throws {
        let harness = try makeHarness(fetchIntents: { _ in throw DeployStubFailure() })
        let skill = try insertSkill(context: harness.context)
        for machineID in [localID, remoteID] {
            harness.context.insert(MachineDeployIntent(
                machineID: machineID, skillSlug: skill.directoryName,
                platformRaw: PlatformTarget.codex.rawValue
            ))
        }
        try harness.context.save()
        let before = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key).sorted()

        do {
            let selected = try harness.model.selectedMachineIDs(
                skills: [skill], platforms: [.codex], context: harness.context
            )
            _ = try harness.model.apply(
                skills: [skill], platforms: [.codex], selectedMachineIDs: selected,
                context: harness.context
            )
            XCTFail("selection read must stop the sheet action")
        } catch {}

        XCTAssertEqual(
            try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key).sorted(), before
        )
        XCTAssertNotNil(harness.model.error)
    }

    func testSuccessfulSelectionReadPreservesEarlierError() throws {
        let harness = try makeHarness()
        harness.model.error = "Machine identity could not be read"

        _ = try harness.model.selectedMachineIDs(
            skills: [], platforms: [.codex], context: harness.context
        )

        XCTAssertEqual(harness.model.error, "Machine identity could not be read")
    }

    func testSheetCountsOnlyPairsChangedByThisAction() throws {
        let harness = try makeHarness()
        let alpha = try insertSkill(context: harness.context)
        let beta = try insertReviewSkill("beta", context: harness.context)
        let gamma = try insertReviewSkill("gamma", context: harness.context)
        let skills = [alpha, beta, gamma]
        _ = try harness.model.apply(
            skills: skills, platforms: [.codex], selectedMachineIDs: [localID],
            context: harness.context
        )

        let deploy = try BulkDeploySheet.perform(
            .deploy, forProject: false, platformVM: harness.platformVM, intentModel: harness.model,
            skills: skills, platforms: [.codex], target: .userWide,
            machineIDs: [localID], context: harness.context
        )
        guard case let .localDeploy(deployResult) = deploy else {
            return XCTFail("expected local deploy result")
        }
        XCTAssertEqual(deployResult.successes.count, 0)

        let emptyHarness = try makeHarness()
        let missing = try insertSkill(context: emptyHarness.context)
        let remove = try BulkDeploySheet.perform(
            .remove, forProject: false, platformVM: emptyHarness.platformVM,
            intentModel: emptyHarness.model, skills: [missing], platforms: [.codex, .hermes],
            target: .userWide, machineIDs: [localID], context: emptyHarness.context
        )
        guard case let .localDeploy(removeResult) = remove else {
            return XCTFail("expected local remove result")
        }
        XCTAssertEqual(removeResult.successes.count, 0)
    }

    func testSingleSwitchIgnoresUnrelatedReconcileFailure() throws {
        let harness = try makeHarness()
        let alpha = try insertSkill(context: harness.context)
        let beta = try insertReviewSkill("beta", context: harness.context)
        harness.platformVM.deploy(skill: alpha, platform: .codex, context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: beta.directoryName, platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()
        try writeReviewManifest(harness)
        harness.linkService.throwOnLink = [.codex]
        harness.linkService.unlinkCalls.removeAll()

        let result = try harness.model.set(
            false, skill: alpha, platform: .codex, target: .userWide, context: harness.context
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(try harness.platformVM.artifactIsOwned(skill: alpha, platform: .codex))
        XCTAssertEqual(harness.linkService.unlinkCalls.map(\.directoryName), ["alpha"])
        XCTAssertNil(harness.model.error)
    }

    func testSingleSwitchIgnoresSamePairFailureForAnotherScope() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        let project = try insertReviewProject(context: harness.context)
        harness.linkService.fileService.directories.insert(project.path)
        harness.platformVM.deploy(skill: skill, platform: .codex, context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: skill.directoryName,
            platformRaw: PlatformTarget.codex.rawValue, projectKey: project.identityKey
        ))
        try harness.context.save()
        try writeReviewManifest(harness)
        harness.linkService.throwOnLinkPaths.insert(
            harness.linkService.linkPath(skill: skill, platform: .codex, projectPath: project.path)
        )

        let result = try harness.model.set(
            false, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(try harness.platformVM.artifactIsOwned(skill: skill, platform: .codex))
        XCTAssertNil(harness.model.error)
    }

    func testRepairAndOtherOwnerRemovalIgnoreUnrelatedReconcileFailure() throws {
        let harness = try makeHarness()
        let alpha = try insertSkill(context: harness.context)
        let beta = try insertReviewSkill("beta", context: harness.context)
        _ = try harness.model.set(
            true, skill: alpha, platform: .codex, target: .userWide, context: harness.context
        )
        let alphaPath = harness.linkService.linkPath(skill: alpha, platform: .codex, projectPath: nil)
        try harness.linkService.fileService.deleteFile(at: alphaPath)
        harness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: beta.directoryName, platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()
        try writeReviewManifest(harness)
        harness.linkService.throwOnLinkPaths.insert(
            harness.linkService.linkPath(skill: beta, platform: .codex, projectPath: nil)
        )

        _ = try harness.model.set(
            true, skill: alpha, platform: .codex, target: .userWide, context: harness.context
        )
        XCTAssertTrue(harness.platformVM.isDeployed(skill: alpha, platform: .codex))
        XCTAssertNil(harness.model.error)

        harness.context.insert(ScenarioAssignment(skillID: alpha.id, platform: .codex))
        try harness.context.save()
        _ = try harness.model.set(
            false, skill: alpha, platform: .codex, target: .userWide, context: harness.context
        )
        XCTAssertFalse(try harness.platformVM.artifactIsOwned(skill: alpha, platform: .codex))
        XCTAssertNil(harness.model.error)
    }

    func testTargetStateNotOtherScopeSuccessDeterminesSingleSwitchWork() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        let project = try insertReviewProject(context: harness.context)
        harness.linkService.fileService.directories.insert(project.path)
        harness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: skill.directoryName,
            platformRaw: PlatformTarget.codex.rawValue, projectKey: project.identityKey
        ))
        harness.context.insert(IntentAssignment(
            skillID: skill.id, platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()
        try writeReviewManifest(harness)

        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )

        XCTAssertTrue(harness.platformVM.isDeployed(skill: skill, platform: .codex, target: .userWide))
        XCTAssertTrue(harness.platformVM.isDeployed(
            skill: skill, platform: .codex, target: .project(project)
        ))
    }

    func testTargetStateNotOtherScopeSuccessDeterminesProjectAndBulkWork() throws {
        let projectHarness = try makeHarness()
        let projectSkill = try insertSkill(context: projectHarness.context)
        let project = try insertReviewProject(context: projectHarness.context)
        projectHarness.linkService.fileService.directories.insert(project.path)
        projectHarness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: projectSkill.directoryName,
            platformRaw: PlatformTarget.codex.rawValue
        ))
        projectHarness.context.insert(IntentAssignment(
            skillID: projectSkill.id, platformRaw: PlatformTarget.codex.rawValue, projectID: project.id
        ))
        try projectHarness.context.save()
        try writeReviewManifest(projectHarness)

        _ = try projectHarness.model.setProjectSelection(
            true, skills: [projectSkill], platforms: [.codex], project: project,
            context: projectHarness.context
        )
        XCTAssertTrue(projectHarness.platformVM.isDeployed(
            skill: projectSkill, platform: .codex, target: .project(project)
        ))

        let bulkHarness = try makeHarness()
        let alpha = try insertSkill(context: bulkHarness.context)
        let beta = try insertReviewSkill("beta", context: bulkHarness.context)
        bulkHarness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: alpha.directoryName, platformRaw: PlatformTarget.codex.rawValue
        ))
        bulkHarness.context.insert(IntentAssignment(
            skillID: alpha.id, platformRaw: PlatformTarget.codex.rawValue
        ))
        bulkHarness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: beta.directoryName, platformRaw: PlatformTarget.codex.rawValue
        ))
        try bulkHarness.context.save()
        try writeReviewManifest(bulkHarness)
        bulkHarness.linkService.throwOnLinkPaths.insert(
            bulkHarness.linkService.linkPath(skill: beta, platform: .codex, projectPath: nil)
        )

        let outcome = try bulkHarness.model.apply(
            skills: [alpha], platforms: [.codex], selectedMachineIDs: [localID],
            context: bulkHarness.context
        )
        guard case let .localDeploy(result) = outcome else { return XCTFail("expected local result") }
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(bulkHarness.platformVM.isDeployed(skill: alpha, platform: .codex))
        XCTAssertNil(bulkHarness.model.error)
    }

    func testFailedSaveRestoresContextManifestAndSwitchState() throws {
        var onSaveAttempts = 0
        let failedOn = try makeHarness(saveContext: { context in
            onSaveAttempts += 1
            if onSaveAttempts == 1 { throw DeployStubFailure() }
            try context.save()
        })
        let onSkill = try insertSkill(context: failedOn.context)
        let onPath = reviewIntentPath(failedOn, slug: onSkill.directoryName)

        XCTAssertThrowsError(try failedOn.model.set(
            true, skill: onSkill, platform: .codex, target: .userWide, context: failedOn.context
        ))
        try failedOn.context.save()
        XCTAssertEqual(try failedOn.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertFalse(failedOn.manifestFileService.fileExists(at: onPath))
        XCTAssertFalse(try failedOn.platformVM.artifactIsOwned(skill: onSkill, platform: .codex))

        var offSaveAttempts = 0
        let failedOff = try makeHarness(saveContext: { context in
            offSaveAttempts += 1
            if offSaveAttempts == 2 { throw DeployStubFailure() }
            try context.save()
        })
        let offSkill = try insertSkill(context: failedOff.context)
        _ = try failedOff.model.set(
            true, skill: offSkill, platform: .codex, target: .userWide, context: failedOff.context
        )
        let offPath = reviewIntentPath(failedOff, slug: offSkill.directoryName)
        let before = try failedOff.manifestFileService.readData(at: offPath)

        XCTAssertThrowsError(try failedOff.model.set(
            false, skill: offSkill, platform: .codex, target: .userWide, context: failedOff.context
        ))
        try failedOff.context.save()
        XCTAssertEqual(try failedOff.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertEqual(try failedOff.manifestFileService.readData(at: offPath), before)
        XCTAssertTrue(failedOff.platformVM.isDeployed(skill: offSkill, platform: .codex))
    }

    func testFailedSaveReportsManifestRestoreFailureAndLeavesNoPendingIntent() throws {
        var writes = 0
        let harness = try makeHarness(
            writeManifest: { _ in
                writes += 1
                if writes == 2 { throw DeployStubFailure() }
            },
            saveContext: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        let skill = try insertSkill(context: harness.context)

        XCTAssertThrowsError(try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        ))
        try harness.context.save()
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertTrue(harness.model.error?.contains("restore") == true)
    }

    func testProjectOnlyIntentDoesNotCreateMachinePickerEntry() throws {
        let harness = try makeHarness(states: [])
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: PlatformTarget.codex.rawValue,
            projectKey: "github.com/owner/project"
        ))
        try harness.context.save()

        harness.model.reload(context: harness.context)
        XCTAssertNil(harness.model.machines.first { $0.id == remoteID })

        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()
        harness.model.reload(context: harness.context)
        XCTAssertNotNil(harness.model.machines.first { $0.id == remoteID })
    }
}

@MainActor
private extension DeployIntentModelTests {
    func insertReviewSkill(_ slug: String, context: ModelContext) throws -> Skill {
        let skill = Skill(name: slug.capitalized, directoryName: slug)
        context.insert(skill)
        try context.save()
        return skill
    }

    func insertReviewProject(context: ModelContext, suffix: String = "project") throws -> Project {
        let project = Project(name: suffix.capitalized, path: "/tmp/" + suffix)
        project.identityKey = "github.com/owner/" + suffix
        context.insert(project)
        try context.save()
        return project
    }

    func writeReviewManifest(_ harness: Harness) throws {
        let service = ManifestService(fileService: harness.manifestFileService)
        try service.write(try service.snapshot(from: harness.context), toRoot: harness.root)
    }

    func reviewIntentPath(_ harness: Harness, slug: String) -> String {
        harness.root + "/manifest/deploys/" + localID + "/" + slug + ".yaml"
    }
}
