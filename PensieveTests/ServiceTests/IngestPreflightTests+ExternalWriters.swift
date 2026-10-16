import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testImportAfterExternalFastForwardKeepsPulledCategory() async throws {
        try await assertExternalWriter(.importSkill)
    }

    func testWindowAndCLIDeployAfterExternalFastForwardKeepPulledCategory() async throws {
        for writer in [ExternalWriter.windowDeploy, .cliDeploy] { try await assertExternalWriter(writer) }
    }

    func testRemovalAndQueuedSaveAfterExternalFastForwardKeepPulledCategory() async throws {
        for writer in [ExternalWriter.removal, .queuedSave] { try await assertExternalWriter(writer) }
    }

    func testQueuedRenameClashAfterExternalFastForwardKeepsCompletedIngest() async throws {
        let f = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/outside-rename-clash")
        }
        let context = try damageContext(f)
        try NativeTestWork.run {
            try f.changePeer()
            guard case .fastForwarded = try f.git.fastForwardOnly(at: f.app, credential: nil) else {
                return XCTFail("The outside git process must fast-forward the actual store")
            }
        }
        let manifest = WriterIngestManifest()
        let saves = ManifestSaveModel(manifest: manifest, root: f.app, lockPath: f.base + "/sync.lock")
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
        CategoryStore(manifestSaves: saves).rename(category, to: "Added", context: context)
        await saves.waitUntilIdle()
        let notice = try XCTUnwrap(saves.categoryNotice)
        XCTAssertEqual(notice.title, "Category changes couldn't be saved")
        XCTAssertEqual(notice.messages, [
            "Couldn't save the change to “Kept”, so it was undone. A category named “Added” already exists."
        ], "The rename must retain its own name-conflict refusal")
        XCTAssertEqual(manifest.writes, 0, "A refused rename must not publish")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Added", "Kept"],
                       "Completed ingestion must accept the pulled category despite the refused rename")
        XCTAssertEqual(try f.manifest.read(fromRoot: f.app).categories.map(\.name).sorted(), ["Added", "Kept"])
        let following = WriterIngestManifest()
        try performImmediateWriter(.importSkill, fixture: f, context: context, manifest: following)
        XCTAssertEqual(following.reads, 0, "A following writer must reuse the completed ingest at this HEAD")
        XCTAssertEqual(following.writes, 1)
    }

    func testUnreadableHeadRebuildsBeforeImportDeployRemovalAndQueuedSave() async throws {
        for writer in ExternalWriter.allCases { try await assertExternalWriter(writer, unreadableHead: true) }
    }

    func testUnchangedHeadSkipsImportAndDeployRebuild() throws {
        for writer in [ExternalWriter.importSkill, .windowDeploy] {
            let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/unchanged-\(writer)") }
            let context = try damageContext(f)
            let manifest = WriterIngestManifest()
            XCTAssertFalse(StoreIngestState.shared(for: context.container).needsRebuild)
            try performImmediateWriter(writer, fixture: f, context: context, manifest: manifest)
            XCTAssertEqual(manifest.reads, 0, "Unchanged HEAD must not scan the manifest for a rebuild: \(writer)")
            XCTAssertEqual(manifest.writes, 1, "The writer must actually publish")
        }
    }

    func testStoresWithoutCommitsSkipImportAndDeployRebuild() throws {
        for repository in [false, true] {
            for writer in [ExternalWriter.importSkill, .windowDeploy] {
                let f = try NativeTestWork.run {
                    try IncompleteIngestFixture(base: self.tempDir + "/uncommitted-\(repository)-\(writer)")
                }
                let context = try damageContext(f)
                try NativeTestWork.run {
                    try f.files.deleteDirectory(at: f.app + "/.git")
                    if repository { try f.git.initRepository(at: f.app) }
                }
                // A non-sync launch has no commit stamp, even when its library is populated.
                StoreIngestState.shared(for: context.container).seedHead(nil)
                let manifest = WriterIngestManifest()
                try performImmediateWriter(writer, fixture: f, context: context, manifest: manifest)
                XCTAssertEqual(manifest.reads, 0, "No foreign HEAD exists: repository=\(repository), \(writer)")
                XCTAssertEqual(manifest.writes, 1)
            }
        }
    }

    private func assertExternalWriter(_ writer: ExternalWriter, unreadableHead: Bool = false) async throws {
        let f = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/outside-\(writer)-\(unreadableHead)")
        }
        let context = try damageContext(f)
        let rebuild = IncompleteIngestRebuild()
        // Configure before the writer, so a coordinator-local stamp cannot hide behind fresh setup.
        let coordinator = await makeIncompleteCoordinator(container: context.container, fixture: f, rebuild: rebuild)
        try NativeTestWork.run {
            try f.changePeer()
            guard case .fastForwarded = try f.git.fastForwardOnly(at: f.app, credential: nil) else {
                return XCTFail("The outside git process must fast-forward the actual store")
            }
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Deleted", "Kept"])
        XCTAssertFalse(StoreIngestState.shared(for: context.container).needsRebuild,
                       "This regression must be detected by HEAD, without a failed-ingest flag")
        let headPath = f.app + "/.git/HEAD", head = try f.files.readFile(at: f.app + "/.git/HEAD")
        if unreadableHead {
            try f.files.writeFile(at: headPath, content: "unreadable head\n")
            XCTAssertNil(GitHeadStamp().read(root: f.app))
        }
        defer { if unreadableHead { try? f.files.writeFile(at: headPath, content: head) } }
        let manifest = WriterIngestManifest(), container = context.container
        manifest.beforeWrite = {
            let observed = ModelContext(container)
            XCTAssertEqual(try observed.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Added", "Kept"],
                           "Ingestion must finish before publication")
        }
        if writer == .queuedSave {
            let saves = ManifestSaveModel(manifest: manifest, root: f.app, lockPath: f.base + "/sync.lock")
            let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
            let category = try XCTUnwrap(context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
            CategoryStore(manifestSaves: saves).setSkill(skill, inCategory: category, assigned: true, context: context)
            await saves.waitUntilIdle()
            XCTAssertEqual(saves.pendingCount, 0)
            XCTAssertNil(saves.categoryNotice)
            XCTAssertGreaterThan(manifest.snapshotsBeforeFirstWrite, 0, "Queue ingestion must precede publication")
            XCTAssertEqual(try f.manifest.read(fromRoot: f.app).categories.first { $0.name == "Kept" }?.skillSlugs, ["item"])
        } else {
            try performImmediateWriter(writer, fixture: f, context: context, manifest: manifest)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Added", "Kept"],
                       "The window must reflect the outside pull when \(writer) finishes")
        XCTAssertEqual(try f.manifest.read(fromRoot: f.app).categories.map(\.name).sorted(), ["Added", "Kept"])
        if unreadableHead { try f.files.writeFile(at: headPath, content: head) }
        guard case .synced = await coordinator.runCycle() else { return XCTFail("Next sync must succeed") }
        if !unreadableHead {
            XCTAssertEqual(rebuild.calls, 1, "Coordinator must reuse the writer's ingest and only rebuild after its pull")
        }
        try NativeTestWork.run { try f.assertRemoteCategories() }
    }

    private func performImmediateWriter(_ writer: ExternalWriter, fixture f: IncompleteIngestFixture,
                                        context: ModelContext, manifest: WriterIngestManifest) throws {
        switch writer {
        case .importSkill:
            let model = importModel(fixture: f, manifest: manifest)
            _ = model.importSelected(context: context)
            XCTAssertNil(model.error)
            XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "imported" })
        case .windowDeploy, .cliDeploy:
            let platform = intentPlatform(fixture: f, installed: [.codex]).platform
            let model = DeployIntentModel(platformVM: platform, dependencies: DeployIntentDependencies(
                identity: InertMachineIdentity(), stateService: InertMachineStateService(), root: f.app,
                manifestService: manifest,
                writeManifest: { try manifest.write(try manifest.snapshot(from: $0), toRoot: f.app) },
                notifier: {}, lockPath: f.base + "/sync.lock"))
            if writer == .windowDeploy {
                let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
                try model.setRemote(true, machineID: ProjectIntentHarness.remoteID,
                    projectKey: "github.com/owner/project", skill: skill, platform: .codex, context: context)
            } else {
                let reply = CLIDeployHandler(service: model.service, files: f.files).handle(CLIRequest(command: "deploy",
                    arguments: ["item"], deployment: CLIDeployOptions(agents: ["codex"], global: true,
                        workingDirectory: f.base)), context: context)
                XCTAssertTrue(reply.envelope.ok, String(describing: reply.envelope.error))
            }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        case .removal:
            let project = Project(name: "Local", path: f.base + "/project")
            project.identityKey = "github.com/owner/project"
            try f.files.createDirectory(at: project.path)
            context.insert(project)
            try context.save()
            let platform = intentPlatform(fixture: f, installed: []).platform
            let removal = ProjectRemovalModel()
            removal.request(project, platformVM: platform, context: context)
            XCTAssertNotNil(removal.preview)
            let result = removal.confirm { selected, preview in
                removeRegisteredProject(selected, reconciler: NoopProjectCategoryReconciler(),
                    manifestService: manifest, manifestRoot: f.app, platformVM: platform,
                    localMachineID: InertMachineIdentity.value, confirmedPreview: preview,
                    context: context, lockPath: f.base + "/sync.lock")
            }
            XCTAssertNil(removal.error)
            XCTAssertFalse(result.hasFailures, result.operationFailures.joined(separator: ", "))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 0)
        case .queuedSave: XCTFail("Queued writer is asynchronous")
        }
    }
}

private enum ExternalWriter: CaseIterable { case importSkill, windowDeploy, cliDeploy, removal, queuedSave }

/// Counts real ingest reads and preparation snapshots; never supplies a canned rebuild result.
/// The queue's prepare snapshot must occur before its first publication. Immediate writers use
/// read count to prove the unchanged-HEAD path performs no rebuild.
final class WriterIngestManifest: ManifestSnapshotting {
    func repair(_ snapshot: ManifestSnapshot, root: String, replacing damage: ManifestDamage) throws -> Bool {
        try manifest.repair(snapshot, root: root, replacing: damage)
    }
    private let manifest = ManifestService()
    var beforeWrite: (() throws -> Void)?
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var snapshots = 0
    private(set) var snapshotsBeforeFirstWrite = 0
    func read(fromRoot root: String) throws -> ManifestSnapshot {
        reads += 1
        return try manifest.read(fromRoot: root)
    }
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot {
        snapshots += 1
        return try manifest.snapshot(from: context)
    }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        try beforeWrite?()
        if writes == 0 { snapshotsBeforeFirstWrite = snapshots }
        writes += 1
        try manifest.write(snapshot, toRoot: root)
    }
}
