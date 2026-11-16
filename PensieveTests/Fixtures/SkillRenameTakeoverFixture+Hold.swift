import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension SkillRenameTakeoverFixture {
    static let holdSentence = "Its changes stay on this Mac until you rename it."

    func beginHold(queuedTags: Bool = false, unreadableDate: Bool = false,
                   unrewritable: Bool = false, keepOldFolder: Bool = false,
                   rebuildFails: RecordingSaveManifest? = nil) async throws -> ManifestSnapshot {
        XCTAssertTrue(rename(), library.error ?? "")
        let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { held.release() }
        if queuedTags { library.updateMetadata(skill, tags: ["queued"], scope: .project, context: context) }
        try arrivePeer()
        if unrewritable {
            try files.writeFile(at: store.baseDir + "/zulu/SKILL.md", content: "No frontmatter to rewrite.")
        } else {
            _ = try store.createSkill(name: "Alpha", description: "Returned", body: "Same creation returned.")
        }
        if unreadableDate {
            let path = root + "/manifest/skills/zulu.yaml"
            let text = try files.readFile(at: path)
            let changed = text.split(separator: "\n").map {
                $0.hasPrefix("created_at:") ? "created_at: unreadable" : String($0)
            }.joined(separator: "\n") + "\n"
            try files.writeFile(at: path, content: changed)
        }
        if let rebuildFails {
            try moveHead()
            rebuildFails.failingRebuildSnapshots = 1
        }
        let before = try manifest.read(fromRoot: root)
        try rememberGuardedRecords(comparingPeerBytes: !unreadableDate)
        held.release()
        await saves.waitUntilIdle()
        if !unrewritable, !keepOldFolder {
            try store.deleteSkill(directoryName: "alpha")
            for row in try context.fetch(FetchDescriptor<Skill>()) where row.directoryName == "alpha" {
                context.delete(row)
            }
            try context.save()
        }
        return before
    }

    /// Sync's admission, rebuild and whole-library publication, with no remote network involved.
    func syncHeld() throws {
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: root, context: context)
        let snapshot = try StoreIngestState.snapshotForPublication(using: manifest, context: context,
            root: root, guardingPendingRenames: true)
        try manifest.write(snapshot, toRoot: root)
        XCTAssertFalse(StoreRebuildService().rebuild(fromRoot: root, context: context).ingestIncomplete)
    }

    func rememberGuardedRecords(comparingPeerBytes: Bool = true) throws {
        for slug in ["alpha", "zulu"] where slug != "zulu" || comparingPeerBytes {
            guardedRecordBytes[slug] = try files.readData(at: root + "/manifest/skills/" + slug + ".yaml")
        }
    }

    func assertGuarded(_ before: ManifestSnapshot, bytes: Data? = nil,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let disk = try manifest.read(fromRoot: root)
        for slug in ["alpha", "zulu"] {
            XCTAssertEqual(disk.skills.first { $0.slug == slug }, before.skills.first { $0.slug == slug }, file: file, line: line)
        }
        XCTAssertEqual(disk.categories, before.categories, file: file, line: line)
        XCTAssertEqual(disk.deployIntents.filter { ["alpha", "zulu"].contains($0.skillSlug) },
            before.deployIntents.filter { ["alpha", "zulu"].contains($0.skillSlug) }, file: file, line: line)
        if let bytes {
            XCTAssertEqual(try files.readData(at: root + "/manifest/skills/zulu.yaml"), bytes, file: file, line: line)
        }
        for (slug, original) in guardedRecordBytes {
            XCTAssertEqual(try files.readData(at: root + "/manifest/skills/" + slug + ".yaml"),
                original, file: file, line: line)
        }
    }

    func editHeld() async {
        library.updateMetadata(skill, tags: ["latest"], scope: .project, context: context)
        await saves.waitUntilIdle()
        library.updateMetadata(skill, tags: ["latest"], scope: .user, context: context)
        await saves.waitUntilIdle()
    }

    func renameHeld(to name: String = "Free") -> Bool {
        SkillRenameFlow.rename(skill: skill, to: name, library: library, platformVM: platform,
            projects: projects, context: context)
    }

    func deleteHeld() -> Bool {
        SkillDeletionFlow.delete(skill: skill, library: library, platformVM: platform,
            projects: projects, context: context)
    }

    func assertPublished(_ slug: String, tags: [String] = ["latest"], scope: SkillScope = .user,
                         carriesOld: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        let disk = try manifest.read(fromRoot: root)
        var expected = own; expected.slug = slug; expected.tags = tags; expected.scope = scope
        XCTAssertEqual(disk.skills.first { $0.slug == slug }, expected, file: file, line: line)
        if carriesOld {
            XCTAssertFalse(disk.skills.contains { $0.slug == "alpha" }, file: file, line: line)
            XCTAssertEqual(disk.categories.first { $0.name == "Own" }?.skillSlugs, [slug], file: file, line: line)
            XCTAssertEqual(disk.deployIntents.filter { $0.projectKey == "github.com/owner/own" }.map(\.skillSlug),
                [slug, slug], file: file, line: line)
        }
        XCTAssertEqual(skill.tags, tags, file: file, line: line)
        XCTAssertEqual(skill.scope, scope, file: file, line: line)
        XCTAssertEqual(skill.createdAt.timeIntervalSince1970, own.createdAt.timeIntervalSince1970,
            accuracy: 0.001, file: file, line: line)
    }

    func reopen(failingRowRead: Bool = false, expectSkill: Bool = true) async throws {
        precondition(persistent)
        runtime?.commandServer?.stop()
        library.stopWatching()
        await saves.waitUntilIdle()
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: storeURL))
        let paths = AppRuntimePaths(storeRoot: root, appSupportDir: (recordPath as NSString).deletingLastPathComponent)
        let defaults = try paths.makeDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set(true, forKey: AppRuntime.migrationDefaultsKey)
        let reader = RecordingSaveManifest()
        reader.failingSnapshots = failingRowRead ? 1 : 0
        saves = ManifestSaveModel(manifest: reader, root: root, lockPath: lockPath,
            refusedCreatesPath: recordPath)
        library = SkillLibraryViewModel(skillStore: store, fileService: files,
            fileWatchService: RecordingWatcher(), manifestRoot: root,
            notifier: SyncStateNotifier.suppressed, manifestSaves: saves)
        tagLibrary = library
        let runtime = try AppRuntime(container: container, platformVM: platform, library: library,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }), defaults: defaults,
            launchBackfill: { _ in }, paths: paths,
            updateCheckOperation: { _ in RuntimeUpdateCheckResult(report: UpdateCheckReport(), skills: [:]) },
            gitUsabilityProbe: { .usable }, coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: RecoveredPresentationEngine(), git: paths.makeGitService(),
                    credentials: InMemoryCredentialStore(), root: paths.storeRoot,
                    audit: SyncAudit(appSupport: paths.appSupportDir),
                    machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService()))
            })
        self.runtime = runtime
        context = container.mainContext
        await runtime.performLaunchWorkIfNeeded(context: context)
        library.stopWatching()
        if expectSkill {
            skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "zulu" })
        }
        other = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "other" })
        let categories = try context.fetch(FetchDescriptor<Pensieve.Category>())
        ownCategory = try XCTUnwrap(categories.first { $0.name == "Own" })
        goneCategory = try XCTUnwrap(categories.first { $0.name == "Gone" })
        projects = try context.fetch(FetchDescriptor<Project>())
    }

    /// Quit before the old worker acquires its lock, then join it before opening another container.
    /// The joined worker cannot stand in for a surviving process.
    func quitWaiting(release held: SyncLock) async {
        let worker = saves.worker
        worker?.cancel()
        for item in saves.items { StoreIngestState.shared(for: context.container).finish(item.id) }
        held.release()
        await worker?.value
    }
}
