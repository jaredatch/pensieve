import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testPeerRepairResumesWaitingEditsWithoutLocalRepair() async throws {
        let cases = PeerRepairHarness.damagePaths.map { ($0, false) } + [("manifest.yaml", true)]
        for (path, untrackedCategories) in cases {
            let h = try await peerRepairHarness(path: path, untrackedCategories: untrackedCategories)
            defer { h.close() }
            let finderFile = h.f.app + "/manifest/categories/.DS_Store"
            try h.f.files.writeFile(at: finderFile, content: "Finder metadata\n")
            for addition in ["deploys/.DS_Store", "deploys/00000000-0000-0000-0000-000000000001/.DS_Store",
                             "categories/node_modules/local.txt", "skills/node_modules/local.txt"] {
                try h.f.files.writeFile(at: h.f.app + "/manifest/" + addition, content: "ignored\n")
            }
            try h.f.files.writeFile(at: h.f.app + "/skills/item/.env", content: "local fixture\n")
            try h.publishRepair()
            let result = try await h.cycle(git: h.tracingGit())
            guard case .synced(_, _, _, _, let pulled) = result else {
                XCTFail("Expected recovery sync for \(path): \(result)")
                continue
            }
            XCTAssertTrue(pulled, "The recovery fast-forward is a pull even when the later rebase is idle")
            let checks = try h.f.files.readFile(at: h.f.base + "/collision-checks").split(separator: "\n")
            XCTAssertEqual(checks.count, 2, "Check once before recovery, then recheck after preparation")
            await h.saves.waitUntilIdle()
            XCTAssertFalse(h.saves.libraryDamaged)
            XCTAssertFalse(h.saves.showsDamageAlert)
            XCTAssertFalse(h.runtime.library.addsFenced)
            XCTAssertNotEqual(h.footer?.label, "Library file damaged")
            XCTAssertEqual(h.saves.pendingCount, 0)
            XCTAssertEqual(try h.f.manifest.read(fromRoot: h.f.app).categories.map(\.name), ["Added", "Waiting"])
            XCTAssertEqual(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(),
                           ["Added", "Waiting"])
            let fresh = h.f.base + "/fresh"
            try NativeTestWork.run { try h.f.git.clone(remote: h.f.remote, into: fresh, credential: nil) }
            let published = try h.f.manifest.read(fromRoot: fresh)
            XCTAssertEqual(published.categories.map(\.name), ["Added", "Waiting"])
            XCTAssertEqual(published.skills.first?.tags, ["waiting"])
        }
    }

    func testPeerRepairClosesConfirmationAndRetiresReplace() async throws {
        let h = try await peerRepairHarness()
        defer { h.close() }
        h.saves.requestRepair()
        XCTAssertTrue(h.saves.showsRepairConfirmation)
        try h.publishRepair()
        guard case .synced = await h.cycle() else { return XCTFail("Expected repaired sync") }
        await h.saves.waitUntilIdle()
        XCTAssertFalse(h.saves.showsRepairConfirmation, "A readable sync closes the repair confirmation")
        XCTAssertNil(h.saves.confirmedDamage, "A repaired library has no confirmation token")
        let before = try ManifestSaveFixture.manifestBytes(root: h.f.app, files: h.f.files)
        let writes = h.manifest.repairs
        await h.saves.replaceWithThisMac(context: h.context)
        XCTAssertEqual(h.manifest.repairs, writes, "A stale Replace must not reach the repair writer")
        XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: h.f.app, files: h.f.files), before)
        try h.f.files.writeFile(at: h.f.app + "/manifest/manifest.yaml", content: "changed after dismissal\n")
        let changed = try ManifestSaveFixture.manifestBytes(root: h.f.app, files: h.f.files)
        await h.saves.replaceWithThisMac(context: h.context)
        XCTAssertTrue(h.saves.libraryDamaged, "A retired Replace must refresh the latest disk state")
        XCTAssertEqual(h.manifest.repairs, writes)
        XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: h.f.app, files: h.f.files), changed)
    }

    func testUncommittedDamageRefusesPeerRepair() async throws {
        for path in PeerRepairHarness.damagePaths + ["categories/.env.yaml", "deploys/not-a-machine"] {
            let h = try await peerRepairHarness(path: path, committed: false)
            defer { h.close() }
            try h.publishRepair()
            await h.assertRefusedUnchanged()
        }
        for addition in ["categories/.env.yaml", "deploys/stray.txt",
                         "deploys/00000000-0000-0000-0000-000000000001/stray.txt"] {
            let h = try await peerRepairHarness(untrackedCategories: true)
            defer { h.close() }
            try h.publishRepair()
            try h.f.files.writeFile(at: h.f.app + "/manifest/" + addition, content: "invalid\n")
            try h.f.files.writeFile(at: h.f.app + "/.git/info/exclude", content: "manifest/" + addition + "\n")
            XCTAssertTrue(try NativeTestWork.run { h.f.git.isWorktreeClean(at: h.f.app) },
                          "The addition must reach the whole-manifest check")
            await h.assertRefusedUnchanged()
        }
    }

    func testDivergedDamageRefusesPeerRepair() async throws {
        let h = try await peerRepairHarness()
        defer { h.close() }
        try NativeTestWork.run {
            try h.f.files.writeFile(at: h.f.app + "/skills/item/local.txt", content: "local commit\n")
            _ = try h.f.git.stageAllAndCommit(at: h.f.app, message: "local divergence")
        }
        try h.publishRepair()
        await h.assertRefusedUnchanged()
    }

    func testStillDamagedPeerFastForwardsAndKeepsWaitingEdits() async throws {
        let h = try await peerRepairHarness()
        defer { h.close() }
        try NativeTestWork.run {
            try h.f.files.writeFile(at: h.f.peer + "/manifest/manifest.yaml", content: "still damaged\n")
            try h.f.files.writeFile(at: h.f.peer + "/skills/item/peer.txt", content: "peer\n")
            _ = try h.f.git.stageAllAndCommit(at: h.f.peer, message: "still damaged")
            try h.f.git.push(at: h.f.peer, credential: nil)
        }
        let expected = GitHeadStamp().read(root: h.f.peer)
        let before = GitHeadStamp().read(root: h.f.app)
        await h.assertDamage(await h.cycle())
        XCTAssertNotEqual(GitHeadStamp().read(root: h.f.app), before)
        XCTAssertEqual(GitHeadStamp().read(root: h.f.app), expected)
        XCTAssertEqual(try h.f.files.readFile(at: h.f.app + "/manifest/manifest.yaml"), "still damaged\n")
        XCTAssertEqual(try h.f.files.readFile(at: h.f.app + "/skills/item/peer.txt"), "peer\n")
    }

    func testDirtyWorktreeKeepsDamageAndWaitingEdits() async throws {
        for kind in ["modified", "staged", "untracked", "ignored ordinary"] {
            let h = try await peerRepairHarness()
            defer { h.close() }
            try h.publishRepair()
            try NativeTestWork.run {
                let path = kind == "modified" ? "skills/item/SKILL.md" : "skills/item/local.txt"
                try h.f.files.writeFile(at: h.f.app + "/" + path, content: "local bytes \(kind)\n")
                if kind == "staged" { try h.f.git.stagePath(path, at: h.f.app) }
                if kind == "ignored ordinary" {
                    _ = try ingestRawGit(["-C", h.f.app, "config", "core.excludesFile", h.f.base + "/ignore"])
                    try h.f.files.writeFile(at: h.f.base + "/ignore", content: "local.txt\n")
                }
            }
            await h.assertRefusedUnchanged()
        }
    }

    func testFailedFetchKeepsDamageAndWaitingEdits() async throws {
        for authentication in [false, true] {
            let h = try await peerRepairHarness()
            defer { h.close() }
            try h.publishRepair()
            if !authentication {
                try NativeTestWork.run { try h.f.git.setRemote("file://" + h.f.base + "/missing.git", at: h.f.app) }
            }
            try await h.assertRefusedUnchanged(git: h.tracingGit(authenticationFailure: authentication))
            let status = try JSONDecoder().decode(DaemonStatus.self,
                from: h.f.files.readData(at: h.f.base + "/audit/daemon-status.json"))
            XCTAssertEqual(status.result, "failed")
            XCTAssertTrue(status.detail.contains(authentication ? "Authentication failed" : "missing.git"), status.detail)
            guard case let .manifestDamaged(message) = h.lastResult else { return XCTFail("Expected damage refusal") }
            XCTAssertTrue(message.contains(authentication ? "access token" : "does not appear to be a git repository"),
                          message)
            XCTAssertFalse(message.contains("git -C"), message)
            XCTAssertFalse(message.contains("fetch origin main"), message)
            XCTAssertFalse(message.contains(h.f.app), message)
            XCTAssertFalse(message.contains(h.f.base), message)
            XCTAssertFalse(message.contains("missing.git"), message)
            XCTAssertFalse(message.contains("\n"), message)
            XCTAssertFalse(message.contains("Please make sure"), message)
            if !authentication {
                XCTAssertTrue(status.detail.contains("fetch origin main"), status.detail)
                XCTAssertTrue(status.detail.contains(h.f.app), status.detail)
                XCTAssertTrue(status.detail.contains("Please make sure"), status.detail)
            }
        }
    }

    func testProtectedLocalCollisionKeepsDamageAndWaitingEdits() async throws {
        let h = try await peerRepairHarness()
        defer { h.close() }
        try h.publishRepair()
        try NativeTestWork.run {
            try h.f.files.writeFile(at: h.f.peer + "/skills/item/.env", content: "peer fixture bytes\n")
            _ = try ingestRawGit(["-C", h.f.peer, "add", "--force", "--", "skills/item/.env"])
            _ = try h.f.git.stageAllAndCommit(at: h.f.peer, message: "tracked peer file")
            try h.f.git.push(at: h.f.peer, credential: nil)
            try h.f.files.writeFile(at: h.f.app + "/.git/info/exclude", content: "skills/item/.env\n")
            try h.f.files.writeFile(at: h.f.app + "/skills/item/.env", content: "local fixture bytes\n")
            XCTAssertTrue(h.f.git.isWorktreeClean(at: h.f.app), "The protected file must reach the collision check")
        }
        await h.assertRefusedUnchanged()
        let status = try JSONDecoder().decode(DaemonStatus.self,
            from: h.f.files.readData(at: h.f.base + "/audit/daemon-status.json"))
        XCTAssertTrue(status.detail.contains("skills/item/.env"), status.detail)
        guard case let .manifestDamaged(message) = h.lastResult else { return XCTFail("Expected damage refusal") }
        XCTAssertTrue(message.contains("skills/item/.env"), message)
    }

    private func peerRepairHarness(path: String = "manifest.yaml", committed: Bool = true,
                                   untrackedCategories: Bool = false) async throws -> PeerRepairHarness {
        let f = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/" + UUID().uuidString)
        }
        let h = try PeerRepairHarness(f: f, context: damageContext(f))
        await h.runtime.bootstrapTask.value
        try NativeTestWork.run {
            if untrackedCategories { try f.files.deleteDirectory(at: f.app + "/manifest/categories") }
            // The manifest writer leaves these containers even when their tracked files are absent.
            for directory in ["categories", "skills", "deploys"] {
                try f.files.createDirectory(at: f.app + "/manifest/" + directory)
            }
            if path == "deploys/not-a-machine" {
                try f.files.createDirectory(at: f.app + "/manifest/" + path)
            } else {
                try f.files.writeFile(at: f.app + "/manifest/" + path, content: "damaged\n")
            }
            if committed {
                _ = try f.git.stageAllAndCommit(at: f.app, message: "committed damage")
                try f.git.push(at: f.app, credential: nil)
                _ = try f.git.fastForwardOnly(at: f.peer, credential: nil)
            }
        }
        let category = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
        let skill = try XCTUnwrap(try h.context.fetch(FetchDescriptor<Skill>()).first)
        CategoryStore(manifestSaves: h.saves).rename(category, to: "Waiting", context: h.context)
        h.runtime.library.updateMetadata(skill, tags: ["waiting"], scope: .user, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.saves.libraryDamaged)
        XCTAssertTrue(h.saves.showsDamageAlert)
        XCTAssertTrue(h.runtime.library.addsFenced)
        XCTAssertFalse(h.runtime.library.categoryEditsFenced)
        XCTAssertEqual(h.saves.pendingCount, 2)
        return h
    }
}

@MainActor
private final class PeerRepairHarness {
    static let damagePaths = ["manifest.yaml", "categories/broken.yaml", "projects.yaml", "skills/item.yaml",
                              "deploys/00000000-0000-0000-0000-000000000001/item.yaml"]
    let f: IncompleteIngestFixture
    let context: ModelContext
    let runtime: AppRuntime
    let saves: ManifestSaveModel
    let manifest = PeerRepairManifest()
    var lastResult: SyncCycleResult?
    var footer: SyncFooterPresentation? {
        SyncFooterPresentation.make(state: .idle, canResolve: false, hovering: false,
                                    now: Date(), libraryDamaged: saves.libraryDamaged)
    }

    init(f: IncompleteIngestFixture, context: ModelContext) throws {
        self.f = f
        self.context = context
        saves = ManifestSaveModel(manifest: manifest, root: f.app, lockPath: f.base + "/sync.lock", waitSeconds: 0.01)
        let paths = AppRuntimePaths(storeRoot: f.app, appSupportDir: f.base + "/support")
        let defaults = try paths.makeDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set("off", forKey: UpdateCheckSchedule.frequencyKey)
        runtime = try AppRuntime(container: context.container, library: f.queuedLibrary(manifestSaves: saves),
            defaults: defaults, paths: paths)
        runtime.library.setLaunchIngestPending(false)
    }

    func close() { runtime.commandServer?.stop(); runtime.library.stopWatching() }

    func publishRepair() throws {
        try NativeTestWork.run { [f] in
            let damage = ManifestDamage.capture(root: f.peer, files: f.files)
            _ = try f.manifest.repair(IncompleteIngestFixture.snapshot(["Added", "Kept"]), root: f.peer, replacing: damage)
            // An uncommitted local-damage fixture has a readable peer already.
            try f.changePeer()
        }
    }

    func cycle(git: GitService? = nil) async -> SyncCycleResult {
        let git = AllowlistedRemoteGit(wrapping: git ?? f.git)
        let engine = SyncEngine(gitService: git, storeRebuildService: StoreRebuildService(),
                                lockPath: f.base + "/sync.lock")
        let coordinator = SyncCoordinator(modelContainer: context.container)
        await coordinator.configure(engine: engine, git: git,
            credentials: IngestEmptyCredentials(), root: f.app, audit: SyncAudit(appSupport: f.base + "/audit"),
            machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService()))
        let result = await coordinator.runCycle()
        lastResult = result
        await runtime.applyLibrarySyncOutcome(result)
        return result
    }

    func assertDamage(_ result: SyncCycleResult, file: StaticString = #filePath, line: UInt = #line) async {
        guard case .manifestDamaged = result else { return XCTFail("Expected damage, got \(result)", file: file, line: line) }
        await saves.waitUntilIdle()
        XCTAssertTrue(saves.libraryDamaged, file: file, line: line)
        XCTAssertTrue(saves.showsDamageAlert, file: file, line: line)
        XCTAssertEqual(footer?.label, "Library file damaged", file: file, line: line)
        XCTAssertEqual(saves.pendingCount, 2, file: file, line: line)
    }

    func assertRefusedUnchanged(git: GitService? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let head = GitHeadStamp().read(root: f.app)
            let before = try worktreeBytes()
            let index = try NativeTestWork.run { [f] in try ingestRawGit(["-C", f.app, "ls-files", "--stage", "-z"]) }
            await assertDamage(await cycle(git: git), file: file, line: line)
            XCTAssertEqual(GitHeadStamp().read(root: f.app), head, file: file, line: line)
            XCTAssertEqual(try worktreeBytes(), before, file: file, line: line)
            XCTAssertEqual(try NativeTestWork.run { [f] in try ingestRawGit(["-C", f.app, "ls-files", "--stage", "-z"]) },
                           index, file: file, line: line)
        } catch { XCTFail("Fixture failed: \(error)", file: file, line: line) }
    }

    func tracingGit(authenticationFailure: Bool = false) throws -> GitService {
        let executable = f.base + "/tracing-git"
        try f.files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            inspect() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = ls-tree ] && [ "$2" = -r ] && [ "$3" = --name-only ]; then
                    printf 'check\\n' >> '\(f.base)/collision-checks'
                fi
                if [ "$1" = fetch ] && [ '\(authenticationFailure)' = true ]; then
                    echo "fatal: Authentication failed for 'https://fixture.test/x.git'" >&2
                    exit 128
                fi
            }
            inspect "$@"
            exec /usr/bin/git "$@"
            """ + "\n")
        return GitService(askpassHelperPath: f.base + "/askpass", executablePath: executable)
    }

    private func worktreeBytes() throws -> [String: Data] {
        var result: [String: Data] = [:]
        func walk(_ relative: String) throws {
            for name in try f.files.listDirectory(at: f.app + relative) where name != ".git" {
                let path = relative + "/" + name
                if f.files.directoryExists(at: f.app + path) {
                    result[path + "/"] = Data()
                    try walk(path)
                } else {
                    result[path] = try f.files.readData(at: f.app + path)
                }
            }
        }
        try walk("")
        return result
    }
}

private final class PeerRepairManifest: ManifestSnapshotting {
    private let base = ManifestService()
    private(set) var repairs = 0
    func read(fromRoot root: String) throws -> ManifestSnapshot { try base.read(fromRoot: root) }
    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws { try base.write(snapshot, toRoot: root) }
    func snapshot(from context: ModelContext) throws -> ManifestSnapshot { try base.snapshot(from: context) }
    func repair(_ snapshot: ManifestSnapshot, root: String, replacing damage: ManifestDamage) throws -> Bool {
        repairs += 1
        return try base.repair(snapshot, root: root, replacing: damage)
    }
}
