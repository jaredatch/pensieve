import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func checkRefusalAcrossSync(_ scenarios: [String]) async throws {
        for scenario in scenarios {
            let h = try ManifestSaveFixture()
            let peer = h.root + "-peer", remote = h.root + "-remote.git"
            defer { for path in [h.root, peer, remote] { try? h.files.deleteDirectory(at: path) } }
            let coordinator = try await categoryUndoCoordinator(h, remote: remote)
            try requireCategorySync(await coordinator.runCycle())
            try NativeTestWork.run { try TestPaths.git.clone(remote: "file://" + remote, into: peer, credential: nil) }
            let context = h.context.container.mainContext
            let local = try XCTUnwrap(try context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Local" })
            let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { lock.release() }
            if scenario == "rename-peer-after-save" {
                h.library.updateMetadata(try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first),
                                         tags: ["ahead"], scope: .user, context: context)
            }
            enqueueCategorySyncEdit(scenario, local: local, context: context, h: h)
            await h.assertWaitingBehindHeldLock(pending: scenario == "rename-peer-after-save" ? 2 : 1,
                                                before: try h.manifestBytes())
            let peerName = try pushCategoryPeer(scenario, peer: peer, h: h)
            let normal = scenario.hasPrefix("create") || scenario.hasSuffix("-normal")
            if !normal {
                _ = try NativeTestWork.run { try TestPaths.git.pullRebase(at: h.root, credential: nil) }
            }
            try requireCategorySync(await coordinator.runCycle())
            let saved = try h.manifest.read(fromRoot: h.root)
            XCTAssertEqual(saved.categories.first { $0.name == peerName }?.projectKeys, ["peer-project"], scenario)
            if !normal, scenario != "delete-schema-gone" {
                XCTAssertTrue(saved.categories.contains { $0.name == "Local" }, scenario)
            }
            if scenario.contains("schema") {
                try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "schema_version: 99\n")
            } else if scenario == "rename-peer-after-save" {
                h.recording.afterWrite = { h.recording.failingWrites = 1 }
            } else { h.recording.failingWrites = 1 }
            lock.release()
            await h.saves.waitUntilIdle()
            h.recording.afterWrite = nil
            try assertCategorySyncNotice(scenario, h: h)
            try assertCategoryWindow(context, matches: saved, phase: scenario + " / refused window")
            try assertCategoryWindow(ModelContext(context.container), matches: saved, phase: scenario + " / persisted window")
            if scenario.contains("schema") {
                try h.files.writeFile(at: h.root + "/manifest/manifest.yaml",
                                      content: "schema_version: \(ManifestService.currentSchemaVersion)\n")
                try h.manifest.write(saved, toRoot: h.root)
            }
            try requireCategorySync(await coordinator.runCycle())
            _ = try NativeTestWork.run { try TestPaths.git.pullRebase(at: peer, credential: nil) }
            XCTAssertEqual(try h.manifest.read(fromRoot: peer).categories, saved.categories, scenario + " / next peer pull")
            try assertCategoryWindow(context, matches: saved, phase: scenario + " / next window")
        }
    }

    private func pushCategoryPeer(_ scenario: String, peer: String, h: ManifestSaveFixture) throws -> String {
        var incoming = try h.manifest.read(fromRoot: peer)
        let name = scenario.hasPrefix("create") ? "Writing" : scenario.hasPrefix("rename-peer") ? "Drafts" : "Peer"
        incoming.categories.append(CategoryRecord(name: name, projectKeys: ["peer-project"], skillSlugs: []))
        if scenario == "delete-schema-gone" { incoming.categories.removeAll { $0.name == "Local" } }
        if scenario == "skill-schema" { incoming.categories[0].skillSlugs = ["alpha", "beta"] }
        if scenario == "project-schema" { incoming.categories[0].projectKeys = ["local-key", "peer-project"] }
        try h.manifest.write(incoming, toRoot: peer)
        XCTAssertTrue(try NativeTestWork.run { try TestPaths.git.stageAllAndCommit(at: peer, message: "peer category") })
        try NativeTestWork.run { try TestPaths.git.push(at: peer, credential: nil) }
        return name
    }

    private func assertCategorySyncNotice(_ scenario: String, h: ManifestSaveFixture) throws {
        if scenario == "rename-normal" {
            XCTAssertNil(h.saves.categoryNotice, "Sync already published the rename; its turn skips the absent old name")
            XCTAssertTrue(h.recording.writes.isEmpty)
            return
        }
        let notice = try XCTUnwrap(h.saves.categoryNotice, scenario).message
        let kept = scenario.hasSuffix("-normal"), gone = scenario == "delete-schema-gone"
        XCTAssertEqual(notice.contains("already saved"), kept, scenario + ": " + notice)
        XCTAssertEqual(notice.contains("It now shows what's saved."), !kept && !gone, scenario + ": " + notice)
        XCTAssertFalse(notice.contains("undone"), scenario + ": " + notice)
        XCTAssertEqual(notice.contains("gone"), gone, scenario + ": " + notice)
        XCTAssertTrue(notice.contains(scenario.hasPrefix("create") ? "Writing" : "Local"), notice)
        XCTAssertTrue(notice.contains(scenario.contains("schema") ? "Update Pensieve"
                      : CocoaError(.fileWriteNoPermission).localizedDescription), notice)
    }

    private func enqueueCategorySyncEdit(_ scenario: String, local: Pensieve.Category,
                                         context: ModelContext, h: ManifestSaveFixture) {
        switch scenario {
        case "create-peer", "create-schema": _ = h.categories.create(name: "Writing", context: context)
        case "delete", "delete-normal", "delete-schema-gone": h.categories.delete(local, context: context)
        case "skill-schema": h.categories.setSkill(h.alpha, inCategory: local, assigned: true, context: context)
        case "project-schema": h.categories.setProject(h.project, inCategory: local, member: true, context: context)
        default: h.categories.rename(local, to: "Drafts", context: context)
        }
    }

    private func categoryUndoCoordinator(_ h: ManifestSaveFixture, remote: String) async throws -> SyncCoordinator {
        try h.files.writeFile(at: h.root + "/.gitignore", content: "support/\n")
        try NativeTestWork.run {
            try TestPaths.git.runOrThrow(["init", "--bare", "--initial-branch=main", remote], in: nil)
            try TestPaths.git.initRepository(at: h.root)
            try TestPaths.git.setRemote("file://" + remote, at: h.root)
            try TestPaths.git.stageAllAndCommit(at: h.root, message: "seed category undo")
            try TestPaths.git.push(at: h.root, credential: nil)
        }
        let container = h.context.container
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        let git = AllowlistedRemoteGit(wrapping: TestPaths.git)
        await coordinator.configure(engine: SyncEngine(gitService: git, lockPath: h.root + "/support/cycle.lock"),
            git: git, credentials: InMemoryCredentialStore(), root: h.root, audit: IngestNullAudit(),
            machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService()))
        return coordinator
    }

    private func requireCategorySync(_ result: SyncCycleResult) throws {
        guard case .synced = result else { XCTFail("Expected sync, got \(result)"); throw CocoaError(.fileReadUnknown) }
    }

    private func assertCategoryWindow(_ context: ModelContext, matches saved: ManifestSnapshot, phase: String) throws {
        let rows = try context.fetch(FetchDescriptor<Pensieve.Category>())
        XCTAssertEqual(rows.count, Set(rows.map(\.name)).count, phase + ": duplicate category names")
        let actual = rows.map {
            CategoryRecord(name: $0.name, projectKeys: $0.projectKeys.sorted(), skillSlugs: $0.skillSlugs.sorted())
        }
        XCTAssertEqual(actual.sorted { $0.name < $1.name }, saved.categories.sorted { $0.name < $1.name }, phase)
    }
}
