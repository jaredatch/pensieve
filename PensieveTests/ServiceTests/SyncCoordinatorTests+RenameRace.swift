import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension SyncCoordinatorTests {
    func testASyncBeforeARefusedRenameIsSavedLeavesTheOtherMacsRecordAlone() async throws {
        let h = try makeRemoteHarness()
        for kind in [RenameRaceKind.unknownDate, .arrivedLater] {
            let race = try await runRenameRace(h, kind: kind)
            try assertRaceLibrary(race, harness: h)
        }
    }

    func testASyncBeforeARefusedRenameIsSavedLeavesARecordSpelledInAnotherCaseAlone() async throws {
        let h = try makeRemoteHarness()
        let race = try await runRenameRace(h, kind: .differentCase)
        try assertRaceLibrary(race, harness: h)
    }

    func testASyncBeforeARefusedRenameIsSavedLeavesThisMacsTagsAndScopeOnItsSkill() async throws {
        let h = try makeRemoteHarness()
        let race = try await runRenameRace(h, kind: .arrivedLater)
        let context = h.container.mainContext
        let rows = try context.fetch(FetchDescriptor<Skill>())
        let skill = try XCTUnwrap(rows.first { $0.id == race.id })
        XCTAssertTrue(skill === race.skill)
        XCTAssertEqual(skill.directoryName, race.own.slug)
        XCTAssertEqual(try ManifestService().snapshot(from: context).skills.first { $0.slug == race.own.slug }, race.own)
        let coordinator = await configuredCoordinator(container: h.container, engine: h.engine,
            git: h.allowlistedGit, root: h.clone)
        try await assertRacePush(coordinator, harness: h)
        let remote = try raceRemoteSnapshot(h, suffix: "second")
        XCTAssertEqual(remote.skills.first { $0.slug == race.own.slug }, race.own)
        let body = try NativeTestWork.run {
            h.git.show(sha: "HEAD", path: "skills/" + race.own.slug + "/SKILL.md", at: h.remotePath)
        }
        XCTAssertTrue(try XCTUnwrap(body).contains("This Mac's text."))
    }

    private func runRenameRace(_ h: RemoteHarness, kind: RenameRaceKind) async throws -> RenameRace {
        let files = FileService(), manifest = ManifestService()
        let context = h.container.mainContext
        let setup = try prepareRenameRace(h, kind: kind)
        let skill = setup.skill, own = setup.own, store = setup.store, peer = setup.peer
        var disk = setup.disk
        let old = own.slug
        let support = h.clone + "/../race-" + kind.rawValue
        let lockPath = support + "/sync.lock"
        let saves = ManifestSaveModel(manifest: manifest, root: h.clone, lockPath: lockPath)
        let library = SkillLibraryViewModel(skillStore: store, fileService: files,
            fileWatchService: RecordingWatcher(), manifestRoot: h.clone,
            notifier: SyncStateNotifier.suppressed, manifestSaves: saves)
        let platform = renameCollisionPlatform(store: store, support: support, files: files)
        var transferred: SyncLock?
        let engine = SyncEngine(gitService: h.allowlistedGit, manifestService: manifest,
            storeRebuildService: StoreRebuildService(), fileService: files, lockPath: lockPath,
            lockProvider: { _ in transferred })
        let coordinator = await configuredCoordinator(container: h.container, engine: engine,
            git: h.allowlistedGit, root: h.clone)
        // No suspension between the rename and lock transfer: the save worker waits behind sync.
        XCTAssertTrue(SkillRenameFlow.rename(skill: skill, to: "Zulu", library: library,
            platformVM: platform, projects: [], context: context))
        transferred = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { transferred?.release() }
        XCTAssertEqual(saves.pendingCount, 1)
        if kind != .unknownDate {
            disk.skills.append(peer)
            try manifest.write(disk, toRoot: h.clone)
        }
        let before = try manifest.read(fromRoot: h.clone)
        let peerBytes = try files.readData(at: h.clone + "/manifest/skills/" + peer.slug + ".yaml")
        try await assertRacePush(coordinator, harness: h)
        await saves.waitUntilIdle()
        XCTAssertEqual(saves.pendingCount, 0)
        XCTAssertEqual(library.error, ManifestSaveError.renameTaken("zulu").localizedDescription)
        XCTAssertEqual(skill.directoryName, old)
        XCTAssertTrue(try store.slugEntryExists(old))
        XCTAssertFalse(try store.slugEntryExists("zulu"))
        return RenameRace(kind: kind, before: before, own: own, peer: peer.slug,
            peerBytes: peerBytes, skill: skill, id: skill.id)
    }

    private func prepareRenameRace(_ h: RemoteHarness, kind: RenameRaceKind) throws
        -> RenameRaceSetup {
        let files = FileService(), manifest = ManifestService()
        let context = h.container.mainContext
        let name = "Alpha " + kind.rawValue
        let old = SkillStore.slugify(name)
        let skill = Skill(name: name, tags: ["own"], scope: .project, directoryName: old,
            cursorConfig: CursorAdapterConfig(description: "Own rules", globs: ["*.swift"]),
            importedFrom: "https://example.com/own")
        skill.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(skill)
        let store = SkillStore(fileService: files, baseDir: h.clone + "/skills", storeRoot: h.clone)
        _ = try store.createSkill(name: name, description: "Local", body: "This Mac's text.")
        try context.save()
        var disk = try manifest.snapshot(from: context)
        let own = try XCTUnwrap(disk.skills.first { $0.slug == old })
        let peer = SkillOverlay(slug: kind == .differentCase ? "Zulu" : "zulu",
            createdAt: Date(timeIntervalSince1970: 1_650_000_000), scope: .user, tags: ["peer"],
            cursor: CursorAdapterConfig(description: "Peer rules", globs: ["*.md"], alwaysApply: true),
            agents: [], origin: .imported(from: "https://example.com/peer"))
        disk.categories = [CategoryRecord(name: "Both", projectKeys: [], skillSlugs: [old, peer.slug])]
        let machine = "12345678-1234-1234-1234-123456789ABC"
        disk.deployIntents = [old, peer.slug].map {
            DeployIntentRecord(machineID: machine, skillSlug: $0, platformRaw: "claudeCode", projectKey: nil)
        }
        if kind == .unknownDate { disk.skills.append(peer) }
        try manifest.write(disk, toRoot: h.clone)
        if kind == .unknownDate {
            let path = h.clone + "/manifest/skills/zulu.yaml"
            let raw = try files.readFile(at: path)
            let unreadable = raw.split(separator: "\n").map {
                $0.hasPrefix("created_at:") ? "created_at: unreadable" : String($0)
            }.joined(separator: "\n") + "\n"
            try files.writeFile(at: path, content: unreadable)
        }
        // Populate assignment rows without letting the folderless peer become a local skill.
        XCTAssertFalse(StoreRebuildService().rebuild(fromRoot: h.clone, context: context).ingestIncomplete)
        XCTAssertTrue(try NativeTestWork.run { try h.git.stageAllAndCommit(at: h.clone, message: "race setup") })
        try NativeTestWork.run { try h.git.push(at: h.clone, credential: nil) }
        StoreIngestState.shared(for: h.container).seedHead(GitHeadStamp().read(root: h.clone))
        return RenameRaceSetup(skill: skill, own: own, store: store, disk: disk, peer: peer)
    }

    private func assertRacePush(_ coordinator: SyncCoordinator, harness h: RemoteHarness) async throws {
        let before = try rawGitOutput(["--git-dir", h.remotePath, "rev-parse", "HEAD"])
        let result = await coordinator.runCycle()
        guard case .synced(let pushed, _, _, _, _) = result else {
            return XCTFail("Expected a successful sync that pushed, got \(result)")
        }
        XCTAssertTrue(pushed)
        XCTAssertNotEqual(try rawGitOutput(["--git-dir", h.remotePath, "rev-parse", "HEAD"]), before)
    }

    private func assertRaceLibrary(_ race: RenameRace, harness h: RemoteHarness) throws {
        let local = try ManifestService().read(fromRoot: h.clone)
        let remote = try raceRemoteSnapshot(h, suffix: race.kind.rawValue)
        for snapshot in [local, remote] {
            XCTAssertEqual(snapshot.skills.first { $0.slug == race.peer }, race.before.skills.first { $0.slug == race.peer })
            XCTAssertEqual(snapshot.skills.first { $0.slug == race.own.slug }, race.own)
            XCTAssertEqual(snapshot.categories, race.before.categories)
            XCTAssertEqual(snapshot.deployIntents, race.before.deployIntents)
        }
        if race.kind != .unknownDate {
            XCTAssertEqual(try FileService().readData(at: h.clone + "/manifest/skills/" + race.peer + ".yaml"), race.peerBytes)
            let remoteBytes = try NativeTestWork.run {
                h.git.show(sha: "HEAD", path: "manifest/skills/" + race.peer + ".yaml", at: h.remotePath)
            }
            XCTAssertEqual(remoteBytes?.data(using: .utf8), race.peerBytes)
        }
    }

    private func raceRemoteSnapshot(_ h: RemoteHarness, suffix: String) throws -> ManifestSnapshot {
        let path = h.clone + "/../inspect-" + suffix
        try NativeTestWork.run { try h.git.clone(remote: h.remote, into: path, credential: nil) }
        return try ManifestService().read(fromRoot: path)
    }
}

private enum RenameRaceKind: String {
    case unknownDate = "unknown"
    case arrivedLater = "late"
    case differentCase = "case"
}

private struct RenameRace {
    let kind: RenameRaceKind
    let before: ManifestSnapshot
    let own: SkillOverlay
    let peer: String
    let peerBytes: Data
    let skill: Skill
    let id: UUID
}

private struct RenameRaceSetup {
    let skill: Skill
    let own: SkillOverlay
    let store: SkillStore
    let disk: ManifestSnapshot
    let peer: SkillOverlay
}
