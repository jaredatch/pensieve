import Foundation
import SwiftData
import XCTest
@testable import Pensieve

private struct IntentEndToEndIdentity: MachineIdentityProviding {
    let id: String
    func identifier() throws -> String { id }
}

private struct IntentEndToEndStateService: MachineStateServicing {
    func compose(machineID: String, context: ModelContext, publishedAt: Date) throws -> MachineState {
        throw DeployStubFailure()
    }
    func write(_ state: MachineState, toRoot root: String) throws {}
    func readAll(fromRoot root: String) -> [MachineState] { [] }
}

@MainActor
final class IntentEndToEndTests: XCTestCase {
    private let machineA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let machineB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private var tempDir = ""

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveIntentEndToEnd-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? FileManager.default.removeItem(atPath: tempDir) }
    }

    func testIntentMaterializesOnTargetClone() throws {
        let harness = try makeHarness()
        let managed = try skill("managed", context: harness.contextA)

        let outcome = try harness.modelA.apply(
            skills: [managed], platforms: [.claudeCode, .codex],
            selectedMachineIDs: [machineB], context: harness.contextA
        )
        guard case .intentOnly = outcome else { return XCTFail("expected remote intent") }
        try syncIntentToTarget(harness)

        XCTAssertEqual(Set(harness.linkService.linkCalls), Set([
            DeployRecordedLink(directoryName: "managed", platform: .claudeCode, projectPath: nil),
            DeployRecordedLink(directoryName: "managed", platform: .codex, projectPath: nil)
        ]))
        let rows = try assignmentRows(container: harness.containerB)
        let targetSkill = try skill("managed", context: ModelContext(harness.containerB))
        XCTAssertEqual(Set(rows.map(\.key)), Set([
            targetSkill.id.uuidString + "|" + PlatformTarget.claudeCode.rawValue,
            targetSkill.id.uuidString + "|" + PlatformTarget.codex.rawValue
        ]))
    }

    func testRetractionPropagates() throws {
        let harness = try makeHarness()
        let managed = try skill("managed", context: harness.contextA)
        _ = try harness.modelA.apply(
            skills: [managed], platforms: [.claudeCode, .codex],
            selectedMachineIDs: [machineB], context: harness.contextA
        )
        try syncIntentToTarget(harness)
        harness.linkService.unlinkCalls.removeAll()

        _ = try harness.modelA.retract(
            skills: [managed], platforms: [.codex], machineIDs: [machineB], context: harness.contextA
        )
        try syncIntentToTarget(harness)

        XCTAssertEqual(harness.linkService.unlinkCalls, [
            DeployRecordedLink(directoryName: "managed", platform: .codex, projectPath: nil)
        ])
        let targetSkill = try skill("managed", context: ModelContext(harness.containerB))
        XCTAssertEqual(try assignmentRows(container: harness.containerB).map(\.key), [
            targetSkill.id.uuidString + "|" + PlatformTarget.claudeCode.rawValue
        ])
    }

    func testRuntimeConvergenceRefreshesAfterPulledRetraction() throws {
        let harness = try makeHarness()
        let managed = try skill("managed", context: harness.contextA)
        _ = try harness.modelA.apply(
            skills: [managed], platforms: [.codex],
            selectedMachineIDs: [machineB], context: harness.contextA
        )
        try syncIntentToTarget(harness)
        let targetSkill = try skill("managed", context: ModelContext(harness.containerB))
        XCTAssertTrue(try harness.platformVMB.artifactIsOwned(skill: targetSkill, platform: .codex))

        _ = try harness.modelA.retract(
            skills: [managed], platforms: [.codex], machineIDs: [machineB], context: harness.contextA
        )
        let pushed = try harness.engineA.sync(
            root: harness.cloneA, message: "A retract", credential: nil, context: harness.contextA
        )
        guard case .synced = pushed else { return XCTFail("clone A did not sync: \(pushed)") }
        let pulled = try harness.engineB.sync(
            root: harness.cloneB, message: "B retract ingest", credential: nil, context: harness.contextB
        )
        guard case .synced = pulled else { return XCTFail("clone B did not sync: \(pulled)") }
        let refreshBefore = harness.platformVMB.refreshCounter
        harness.convergenceB.run(after: .synced(
            pushed: false, warnings: [], completedAt: Date(), headAdvanced: true
        ))

        XCTAssertEqual(harness.platformVMB.refreshCounter, refreshBefore + 2)
        XCTAssertFalse(try harness.platformVMB.artifactIsOwned(skill: targetSkill, platform: .codex))
    }

    func testManualDeploySurvivesEndToEnd() throws {
        let harness = try makeHarness()
        let managed = try skill("managed", context: harness.contextA)
        let manual = try skill("manual", context: harness.contextB)
        harness.platformVMB.deploy(
            skill: manual, platform: .codex, target: .userWide, context: harness.contextB
        )
        let manualPath = harness.linkService.linkPath(
            skill: manual, platform: .codex, projectPath: nil
        )
        harness.linkService.unlinkCalls.removeAll()

        _ = try harness.modelA.apply(
            skills: [managed], platforms: [.codex],
            selectedMachineIDs: [machineB], context: harness.contextA
        )
        try syncIntentToTarget(harness)
        _ = try harness.modelA.retract(
            skills: [managed], platforms: [.codex], machineIDs: [machineB], context: harness.contextA
        )
        try syncIntentToTarget(harness)

        XCTAssertTrue(harness.fileService.symlinks.contains(manualPath))
        XCTAssertFalse(harness.linkService.unlinkCalls.contains { $0.directoryName == "manual" })
        let context = ModelContext(harness.containerB)
        let manualRecords = try context.fetch(FetchDescriptor<DeployRecord>()).filter {
            $0.skillID == manual.id && $0.platform == .codex && $0.projectID == nil
        }
        XCTAssertEqual(manualRecords.count, 1)
        XCTAssertTrue(try assignmentRows(container: harness.containerB).isEmpty)
    }
}

@MainActor
private extension IntentEndToEndTests {
    struct Harness {
        let cloneA: String
        let cloneB: String
        let containerB: ModelContainer
        let contextA: ModelContext
        let contextB: ModelContext
        let engineA: SyncEngine
        let engineB: SyncEngine
        let modelA: DeployIntentModel
        let convergenceB: PostSyncConvergence
        let platformVMB: PlatformViewModel
        let fileService: DeployRecordingFileService
        let linkService: DeployRecordingLinkService
    }

    func makeHarness() throws -> Harness {
        let git = GitService()
        let manifest = ManifestService()
        let remote = try seedRemote(git: git, manifest: manifest)
        let cloneA = tempDir + "/cloneA"
        let cloneB = tempDir + "/cloneB"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)

        let containerA = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let containerB = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let contextA = ModelContext(containerA)
        let contextB = ModelContext(containerB)
        _ = StoreRebuildService().rebuild(fromRoot: cloneA, context: contextA)
        _ = StoreRebuildService().rebuild(fromRoot: cloneB, context: contextB)

        let fileService = DeployRecordingFileService()
        let linkService = DeployRecordingLinkService(fileService: fileService)
        let platformVMB = makePlatformVM(
            fileService: fileService, linkService: linkService, installed: [.claudeCode, .codex]
        )
        let platformVMA = makePlatformVM(
            fileService: DeployRecordingFileService(), installed: [.claudeCode, .codex]
        )
        let identityA = IntentEndToEndIdentity(id: machineA)
        let identityB = IntentEndToEndIdentity(id: machineB)
        let modelA = makeModelA(
            platformVM: platformVMA, identity: identityA, root: cloneA, manifest: manifest
        )
        let convergenceB = makeConvergenceB(
            root: cloneB, container: containerB, platformVM: platformVMB, identity: identityB
        )
        let allowedGit = AllowlistedRemoteGit(wrapping: git)
        let engineA = makeEngine(git: allowedGit, manifest: manifest, lockName: "cloneA")
        let engineB = makeEngine(git: allowedGit, manifest: manifest, lockName: "cloneB")
        return Harness(
            cloneA: cloneA, cloneB: cloneB, containerB: containerB,
            contextA: contextA, contextB: contextB, engineA: engineA, engineB: engineB,
            modelA: modelA, convergenceB: convergenceB, platformVMB: platformVMB,
            fileService: fileService, linkService: linkService
        )
    }

    func makeModelA(
        platformVM: PlatformViewModel,
        identity: IntentEndToEndIdentity,
        root: String,
        manifest: ManifestService
    ) -> DeployIntentModel {
        DeployIntentModel(
            platformVM: platformVM,
            dependencies: DeployIntentDependencies(
                identity: identity,
                stateService: IntentEndToEndStateService(),
                root: root,
                writeManifest: { context in
                    try manifest.write(try manifest.snapshot(from: context), toRoot: root)
                },
                notifier: {},
                reconcile: { context in
                    IntentReconciler(platformVM: platformVM, machineIdentity: identity, handoverIsComplete: { false })
                        .reconcile(context: context)
                },
                lockPath: tempDir + "/cloneA-sync.lock"
            )
        )
    }

    func makeConvergenceB(
        root: String,
        container: ModelContainer,
        platformVM: PlatformViewModel,
        identity: IntentEndToEndIdentity
    ) -> PostSyncConvergence {
        AppRuntimePaths(
            storeRoot: root, appSupportDir: tempDir + "/cloneB-app-support"
        ).makeConvergence(
            container: container,
            platformVM: platformVM,
            intentReconciler: IntentReconciler(platformVM: platformVM, machineIdentity: identity, handoverIsComplete: { false })
        )
    }

    func makeEngine(
        git: GitServiceProtocol,
        manifest: ManifestService,
        lockName: String
    ) -> SyncEngine {
        SyncEngine(
            gitService: git, manifestService: manifest,
            storeRebuildService: StoreRebuildService(), fileService: FileService(),
            lockPath: tempDir + "/" + lockName + "-sync.lock"
        )
    }

    func makePlatformVM(
        fileService: DeployRecordingFileService,
        linkService: DeployRecordingLinkService? = nil,
        installed: [PlatformTarget]
    ) -> PlatformViewModel {
        let resolvedLink = linkService ?? DeployRecordingLinkService(fileService: fileService)
        return PlatformViewModel(
            fileService: fileService,
            linkService: resolvedLink,
            cursorCompiler: DeployRecordingCursorCompiler(fileService: fileService),
            agentDetection: DeployStubDetection(installed: installed),
            deployStateStore: DeployStateStore.memoryBacked
        )
    }

    func syncIntentToTarget(_ harness: Harness) throws {
        let outcomeA = try harness.engineA.sync(
            root: harness.cloneA, message: "A intent", credential: nil, context: harness.contextA
        )
        guard case .synced = outcomeA else { return XCTFail("clone A did not sync: \(outcomeA)") }
        let outcomeB = try harness.engineB.sync(
            root: harness.cloneB, message: "B ingest", credential: nil, context: harness.contextB
        )
        guard case .synced = outcomeB else { return XCTFail("clone B did not sync: \(outcomeB)") }
        let diskIntents = try ManifestService().read(fromRoot: harness.cloneB).deployIntents
        let rebuiltIntents = try harness.contextB.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(Set(rebuiltIntents.map(\.key)), Set(diskIntents.map {
            $0.machineID + "|" + $0.skillSlug + "|" + $0.platformRaw
        }))
        harness.convergenceB.run(after: .synced(
            pushed: false, warnings: [], completedAt: Date(), headAdvanced: true
        ))
    }

    func assignmentRows(container: ModelContainer) throws -> [IntentAssignment] {
        try ModelContext(container).fetch(FetchDescriptor<IntentAssignment>())
            .sorted { $0.key < $1.key }
    }

    func skill(_ slug: String, context: ModelContext) throws -> Skill {
        try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == slug })
    }

    func seedRemote(git: GitService, manifest: ManifestService) throws -> String {
        let remotePath = tempDir + "/remote.git"
        XCTAssertEqual(try rawGit(["init", "--bare", remotePath]), 0)
        let remote = "file://" + remotePath
        let seed = tempDir + "/seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try git.initRepository(at: seed)
        try git.setRemote(remote, at: seed)
        try writeSkill("managed", root: seed)
        try writeSkill("manual", root: seed)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let overlays = ["managed", "manual"].map {
            SkillOverlay(
                slug: $0, createdAt: createdAt, scope: .user, tags: [], cursor: nil,
                agents: [], origin: .authored
            )
        }
        try manifest.write(
            ManifestSnapshot(
                schemaVersion: 4, categories: [], projects: [], skills: overlays
            ),
            toRoot: seed
        )
        try "manifest/categories/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"
            .write(toFile: seed + "/.gitattributes", atomically: true, encoding: .utf8)
        try ".DS_Store\n".write(toFile: seed + "/.gitignore", atomically: true, encoding: .utf8)
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        return remote
    }

    func writeSkill(_ slug: String, root: String) throws {
        let directory = root + "/skills/" + slug
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try "---\nname: \(slug)\ndescription: \(slug) description\n---\n\nBody\n"
            .write(toFile: directory + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    func rawGit(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        _ = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
