import SwiftData
import XCTest
@testable import Pensieve
@MainActor
final class DeployIntentModelTests: XCTestCase {
    let localID = "11111111-1111-4111-8111-111111111111"
    let remoteID = "22222222-2222-4222-8222-222222222222"
    private let otherRemoteID = "33333333-3333-4333-8333-333333333333"

    func testLocalSelectionDeploysAndRecordsIntent() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)

        let result = try harness.model.setSelected(
            true, machineID: localID, skill: skill, platform: .codex, context: harness.context
        )

        XCTAssertEqual(result?.successes.count, 1)
        XCTAssertEqual(harness.linkService.linkCalls.count, 1)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key), [
            localID + "|alpha|codex"
        ])
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
    }

    func testRemoteSelectionRecordsIntentOnly() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)

        _ = try harness.model.setSelected(
            true, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )

        XCTAssertEqual(harness.linkService.linkCalls.count, 0)
        XCTAssertEqual(try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()).first?.machineID, remoteID)
        XCTAssertTrue(harness.model.availablePlatforms.contains(.hermes))
    }

    func testDeselectRetracts() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        _ = try harness.model.setSelected(
            true, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )
        _ = try harness.model.setSelected(
            false, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )

        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    func testRemoveRemoteOnlyRetractsWithoutLocalRemoval() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        _ = try harness.model.setSelected(
            true, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )
        harness.context.insert(MachineDeployIntent(
            machineID: otherRemoteID, skillSlug: skill.directoryName, platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()
        let intentPath = harness.root + "/manifest/deploys/" + remoteID + "/alpha.yaml"
        XCTAssertTrue(harness.manifestFileService.fileExists(at: intentPath))

        let outcome = try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [remoteID], context: harness.context
        )

        guard case .intentOnly = outcome else { return XCTFail("expected remote-only retraction") }
        let remaining = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(remaining.filter { $0.machineID == remoteID }.count, 0)
        XCTAssertEqual(remaining.map(\.key), [otherRemoteID + "|alpha|codex"])
        XCTAssertFalse(harness.manifestFileService.fileExists(at: intentPath))
        XCTAssertEqual(harness.linkService.linkCalls.count, 0)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 0)
    }

    func testRemoveLocalRetractsAndRemoves() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        _ = try harness.model.setSelected(
            true, machineID: localID, skill: skill, platform: .codex, context: harness.context
        )
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)

        let outcome = try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [localID], context: harness.context
        )

        guard case let .localDeploy(result) = outcome else { return XCTFail("expected local removal") }
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 1)
    }

    func testPerformRemoveUserWideRemoteOnlyRoutesToIntent() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: skill.directoryName, platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()

        let outcome = try BulkDeploySheet.perform(
            .remove, forProject: false, platformVM: harness.platformVM, intentModel: harness.model,
            skills: [skill], platforms: [.codex], target: .userWide,
            machineIDs: [remoteID], context: harness.context
        )

        guard case .intentOnly = outcome else { return XCTFail("expected intent-only removal") }
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 0)
    }

    func testPerformDeployUserWideRemoteOnlyRoutesToIntent() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)

        let outcome = try BulkDeploySheet.perform(
            .deploy, forProject: false, platformVM: harness.platformVM, intentModel: harness.model,
            skills: [skill], platforms: [.codex], target: .userWide,
            machineIDs: [remoteID], context: harness.context
        )

        guard case .intentOnly = outcome else { return XCTFail("expected intent-only deploy") }
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertEqual(harness.linkService.linkCalls.count, 0)
    }

    func testPerformDeployProjectRoutesToBatch() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        let project = Project(name: "Project", path: "/tmp/project")
        harness.context.insert(project)
        try harness.context.save()

        let outcome = try BulkDeploySheet.perform(
            .deploy, forProject: true, platformVM: harness.platformVM, intentModel: harness.model,
            skills: [skill], platforms: [.codex], target: .project(project),
            machineIDs: [remoteID], context: harness.context
        )

        guard case let .localDeploy(batch) = outcome else { return XCTFail("expected project batch deploy") }
        XCTAssertEqual(batch.successes.count, 1)
        XCTAssertEqual(harness.linkService.linkCalls.map(\.projectPath), [project.path])
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    func testRetractNudgesExactlyOnce() throws {
        var nudges = 0
        let harness = try makeHarness(notifier: { nudges += 1 })
        let skill = try insertSkill(context: harness.context)
        _ = try harness.model.setSelected(
            true, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )
        nudges = 0

        _ = try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [remoteID], context: harness.context
        )

        XCTAssertEqual(nudges, 1)
    }

    func testSetSelectedWriteFailureLeavesNoLocalDeploy() throws {
        let harness = try makeHarness(writeManifest: { _ in throw DeployStubFailure() })
        let skill = try insertSkill(context: harness.context)

        XCTAssertThrowsError(try harness.model.setSelected(
            true, machineID: localID, skill: skill, platform: .codex, context: harness.context
        ))

        XCTAssertEqual(harness.linkService.linkCalls.count, 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    func testUnseenMachineMarked() throws {
        let harness = try makeHarness(states: [])
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: PlatformTarget.hermes.rawValue
        ))
        try harness.context.save()

        harness.model.reload(context: harness.context)

        let remote = try XCTUnwrap(harness.model.machines.first { $0.id == remoteID })
        XCTAssertTrue(remote.isUnseen)
        XCTAssertEqual(harness.model.machines.first(where: \.isLocal)?.name, "This Mac")
        XCTAssertTrue(harness.model.availablePlatforms.contains(.hermes))
    }

    func testIntentMutationNudgesScheduler() throws {
        var nudges = 0
        var manifestWrites = 0
        let harness = try makeHarness(
            notifier: { nudges += 1 },
            writeManifest: { _ in manifestWrites += 1 }
        )
        let skill = try insertSkill(context: harness.context)
        _ = try harness.model.setSelected(
            true, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )
        _ = try harness.model.setSelected(
            true, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )
        XCTAssertEqual(nudges, 1, "an idempotent selection is not a second mutation")
        XCTAssertEqual(manifestWrites, 1, "intent is persisted before its scheduler nudge")
        _ = try harness.model.setSelected(
            false, machineID: remoteID, skill: skill, platform: .codex, context: harness.context
        )
        XCTAssertEqual(nudges, 2)
        XCTAssertEqual(manifestWrites, 2)
    }

    func testRemoteApplyDistinguishesSuccessFromFailure() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)

        let outcome = try harness.model.apply(
            skills: [skill], platforms: [.codex], selectedMachineIDs: [remoteID], context: harness.context
        )
        guard case .intentOnly = outcome else { return XCTFail("expected remote-only intent success") }

        var writeAttempts = 0
        let retrying = try makeHarness(writeManifest: { _ in
            writeAttempts += 1
            if writeAttempts == 1 { throw DeployStubFailure() }
        })
        let retryingSkill = try insertSkill(context: retrying.context)
        XCTAssertThrowsError(try retrying.model.apply(
            skills: [retryingSkill], platforms: [.codex],
            selectedMachineIDs: [remoteID], context: retrying.context
        ))
        XCTAssertNotNil(retrying.model.error)
        XCTAssertEqual(try retrying.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        let retry = try retrying.model.apply(
            skills: [retryingSkill], platforms: [.codex],
            selectedMachineIDs: [remoteID], context: retrying.context
        )
        guard case .intentOnly = retry else { return XCTFail("expected retry success") }
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertEqual(try retrying.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertNil(retrying.model.error)
    }

    func testExistingStoreOpensUnderExtendedSchema() throws {
        let directory = NSTemporaryDirectory() + "PensieveSchemaMigration-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let url = URL(fileURLWithPath: directory + "/default.store")
        let oldSchema = Schema([
            Skill.self, Project.self, SkillProjectAssignment.self, ScenarioAssignment.self,
            DeployRecord.self, Category.self, Scenario.self, RepoUpdateCursor.self
        ])
        do {
            let oldContainer = try ModelContainer(
                for: oldSchema, configurations: ModelConfiguration(url: url)
            )
            let oldContext = ModelContext(oldContainer)
            oldContext.insert(Skill(
                name: "Existing", skillDescription: "Existing description", tags: [],
                scope: .user, directoryName: "existing", cursorConfig: nil, importedFrom: nil
            ))
            try oldContext.save()
        }

        let extended = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: url))
        let context = ModelContext(extended)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Skill>()), 1)
        context.insert(MachineDeployIntent(machineID: localID, skillSlug: "existing", platformRaw: "codex"))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
    }
}
@MainActor
extension DeployIntentModelTests {
    struct Harness {
        let context: ModelContext
        let model: DeployIntentModel
        let platformVM: PlatformViewModel
        let linkService: DeployRecordingLinkService
        let root: String
        let manifestFileService: FileService
    }

    func makeHarness(
        states: [MachineState]? = nil,
        notifier: @escaping SyncStateNotifying = {},
        fetchIntents: @escaping (ModelContext) throws -> [MachineDeployIntent] = {
            try $0.fetch(FetchDescriptor<MachineDeployIntent>())
        },
        writeManifest: ((ModelContext) throws -> Void)? = nil,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
        reconcile: ((ModelContext) -> BatchResult)? = nil,
        identity: MachineIdentityProviding? = nil,
        lockPath: String? = nil,
        remoteRetractions: RemoteRetractionStore = RemoteRetractionStore(),
        onWriteManifest: (() -> Void)? = nil,
        onReconcile: (() -> Void)? = nil
    ) throws -> Harness {
        let context = ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
        let fileService = DeployRecordingFileService()
        let linkService = DeployRecordingLinkService(fileService: fileService)
        let platformVM = PlatformViewModel(
            fileService: fileService,
            linkService: linkService,
            cursorCompiler: DeployRecordingCursorCompiler(fileService: fileService),
            agentDetection: DeployStubDetection(installed: [.codex]),
            deployStateStore: DeployStateStore.memoryBacked
        )
        let root = NSTemporaryDirectory() + "PensieveDeployIntent-" + UUID().uuidString
        let manifestFileService = FileService()
        let manifestService = ManifestService(fileService: manifestFileService)
        let resolvedWriteManifest = writeManifest ?? { context in
            onWriteManifest?()
            try manifestService.write(try manifestService.snapshot(from: context), toRoot: root)
        }
        registerCleanup(root: root, fileService: manifestFileService)
        let dependencies = DeployIntentDependencies(
            identity: identity ?? DeployIntentIdentityStub(id: localID),
            stateService: DeployIntentStateStub(states: states ?? [defaultRemoteState()]),
            root: root,
            fetchIntents: fetchIntents,
            writeManifest: resolvedWriteManifest,
            saveContext: saveContext,
            notifier: notifier,
            reconcile: reconcile ?? { context in
                onReconcile?()
                return IntentReconciler(
                    platformVM: platformVM,
                    machineIdentity: DeployIntentIdentityStub(id: self.localID), handoverIsComplete: { false }
                ).reconcile(context: context)
            },
            lockPath: lockPath ?? root + "-sync.lock",
            remoteRetractions: remoteRetractions
        )
        return Harness(
            context: context,
            model: DeployIntentModel(platformVM: platformVM, dependencies: dependencies),
            platformVM: platformVM,
            linkService: linkService,
            root: root,
            manifestFileService: manifestFileService
        )
    }

    func defaultRemoteState() -> MachineState {
        MachineState(
            schemaVersion: 1, machineID: remoteID, name: "Mini", appVersion: "test",
            publishedAt: Date(), agents: [PlatformTarget.hermes.rawValue], projects: [],
            userDeploys: [], projectDeploys: []
        )
    }

    func insertSkill(context: ModelContext) throws -> Skill {
        let skill = Skill(
            name: "Alpha", skillDescription: "Alpha description", tags: [],
            scope: .user, directoryName: "alpha", cursorConfig: nil, importedFrom: nil
        )
        context.insert(skill)
        try context.save()
        return skill
    }

    private func registerCleanup(root: String, fileService: FileService) {
        addTeardownBlock {
            guard fileService.directoryExists(at: root) else { return }
            try fileService.deleteDirectory(at: root)
        }
    }
}
