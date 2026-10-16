import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testRebuildOwnerReadsHeadExactlyBeforeAndAfterTheScan() throws {
        let files = RebuildReadFileService()
        let h = try ManifestSaveFixture(rebuildFiles: files)
        defer { h.cleanup() }
        try NativeTestWork.run { try TestPaths.git.initRepository(at: h.root) }
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(fileService: files),
                                        root: h.root, context: h.context, files: files)
        XCTAssertEqual(files.headReads.value, 2, "One owner samples HEAD around each rebuild")
    }

    func testFirstQueuedSaveAfterPullScansSkillsOnce() async throws {
        let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/one-queue-scan") }
        let context = try damageContext(f)
        try NativeTestWork.run {
            try f.changePeer()
            guard case .fastForwarded = try f.git.fastForwardOnly(at: f.app, credential: nil) else {
                return XCTFail("Fixture must pull an outside commit")
            }
        }
        let files = RebuildReadFileService()
        let saves = ManifestSaveModel(manifest: f.manifest, root: f.app, lockPath: f.base + "/sync.lock", files: files)
        let category = try XCTUnwrap(context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
        CategoryStore(manifestSaves: saves).rename(category, to: "Edited", context: context)
        await saves.waitUntilIdle()
        XCTAssertNil(saves.categoryNotice)
        XCTAssertEqual(files.skillListings.value, 1, "Pre-save ingestion and post-save acceptance share one scan")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["item"],
                       "Reusing the scan must retain canonical skills without an explicit manifest overlay")
        XCTAssertEqual(try f.manifest.read(fromRoot: f.app).categories.map(\.name).sorted(), ["Added", "Edited"])
    }

    func testQueuedCategoryRetriesTransientHeadMovementButBoundsPersistentMovement() async throws {
        for moves in [1, 4] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            try h.files.writeFile(at: h.root + "/.git/HEAD", content: String(repeating: "a", count: 40))
            var scans = 0
            h.recording.afterRebuildSnapshot = {
                scans += 1
                if scans <= moves {
                    try h.files.writeFile(at: h.root + "/.git/HEAD", content: String(repeating: String(scans), count: 40))
                }
            }
            h.categories.rename(h.local, to: "Retained", context: h.context)
            await h.saves.waitUntilIdle()
            if moves == 1 {
                XCTAssertNil(h.saves.categoryNotice, "A transient HEAD race keeps the queued edit")
                XCTAssertTrue(try h.manifest.read(fromRoot: h.root).categories.contains { $0.name == "Retained" })
            } else {
                XCTAssertNotNil(h.saves.categoryNotice)
                XCTAssertLessThanOrEqual(scans, 3, "Persistent movement must refuse after bounded retries")
                XCTAssertEqual(h.local.name, "Local")
            }
        }
    }

    func testGeneratedGitMetadataOccupantsAndHeadForms() throws {
        let files = FileService()
        let oid = String(repeating: "a", count: 40)
        for occupant in ["folder", "gitdir", "missing", "link"] {
            for form in ["loose", "packed", "unborn", "detached", "malformed"] {
                let base = tempDir + "/" + UUID().uuidString
                let root = base + "/store", external = base + "/metadata"
                try files.createDirectory(at: root)
                let git = occupant == "folder" ? root + "/.git" : external
                try files.createDirectory(at: git)
                if occupant == "gitdir" { try files.writeFile(at: root + "/.git", content: "gitdir: ../metadata\n") }
                if occupant == "link" { try files.createSymlink(at: root + "/.git", pointingTo: external) }
                try files.writeFile(at: git + "/HEAD", content: form == "detached" ? oid
                    : form == "malformed" ? "not a HEAD" : "ref: refs/heads/main\n")
                if form == "loose" { try files.writeFile(at: git + "/refs/heads/main", content: oid + "\n") }
                if form == "packed" { try files.writeFile(at: git + "/packed-refs", content: oid + " refs/heads/main\n") }
                let expected: GitHeadStamp.State = occupant == "missing" ? .noRepository
                    : occupant == "link" || form == "malformed" ? .unreadable
                    : form == "unborn" ? .unborn : .resolved(oid)
                XCTAssertEqual(GitHeadStamp(fileService: files).state(root: root), expected, "\(occupant), \(form)")
            }
        }
    }

    func assertContentFreeWriterIngest() async throws {
        for path in ["import", "intent", "sync"] {
            let fixture = try NativeTestWork.run {
                try IncompleteIngestFixture(base: self.tempDir + "/content-free-" + path)
            }
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
            context.insert(MachineDeployIntent(machineID: InertMachineIdentity.value,
                skillSlug: "item", platformRaw: "codex", projectKey: "github.com/owner/kept"))
            try context.save()
            try fixture.files.deleteDirectory(at: fixture.app + "/manifest")
            try fixture.files.writeFile(at: fixture.app + "/manifest/manifest.yaml", content: "schema_version: 1\n")
            StoreIngestState.shared(for: container).invalidate()
            if path == "import" {
                let model = importModel(fixture: fixture, manifest: fixture.manifest)
                if case .refused = model.importSelected(context: context) { XCTFail(model.error ?? "import refused") }
            } else if path == "intent" {
                let model = intentModel(fixture: fixture, manifest: fixture.manifest, saveContext: { try $0.save() })
                try model.setRemote(true, machineID: "22222222-2222-4222-8222-222222222222",
                    projectKey: "github.com/owner/new", skill: XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first),
                    platform: .codex, context: context)
            } else {
                let coordinator = await makeIncompleteCoordinator(container: container, fixture: fixture,
                                                                  rebuild: IncompleteIngestRebuild())
                guard case .synced = await coordinator.runCycle() else { return XCTFail("content-free sync failed") }
            }
            XCTAssertTrue(try fixture.manifest.read(fromRoot: fixture.app).deployIntents.contains {
                $0.projectKey == "github.com/owner/kept"
            }, "\(path) must preserve local intents when the manifest has no authority")
        }
    }
}
