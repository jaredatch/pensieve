import XCTest
@testable import Pensieve

extension SyncBytePreservationTests {
    func testExcludedInventoryPrunesDependencyFoldersAndGuardsChildrenAndParents() throws {
        let root = base + "/pruned-store"
        let native = TestPaths.git
        try files.createDirectory(at: root)
        try native.initRepository(at: root)
        try files.writeFile(at: root + "/skills/x/SKILL.md", content: "tracked skill\n")
        try native.stageAllAndCommit(at: root, message: "base")
        let folders = ["node_modules", "skills/x/node_modules", "skills/new/node_modules",
                       ".env", "skills/x/.env", "skills/new/.env", ".venv", "skills/x/.venv", "skills/new/.venv"]
        for folder in folders {
            for name in ["package/index.js", "package/deep/other.js"] {
                try files.writeFile(at: root + "/" + folder + "/" + name, content: "local dependency\n")
            }
        }
        try files.writeFile(at: root + "/skills/x/sub/.env", content: "local env\n")
        let trace = base + "/inventory-output"
        let recording = try inventoryRecordingGit(trace: trace)
        let store = try recording.storeOperation(at: root)
        let inventory = try store.excludedUntrackedPaths()
        XCTAssertEqual(Set(inventory), Set((folders.map { $0 + "/" } + ["skills/x/sub/.env"]).map { Data($0.utf8) }))
        let nativeInventory = try files.readData(at: trace).split(separator: 0)
        XCTAssertFalse(nativeInventory.isEmpty)
        XCTAssertTrue(nativeInventory.allSatisfy { $0.last == 0x2F },
                      "Git must report dependency directories, never walk their files")
        try files.deleteFile(at: root + "/skills/x/sub/.env")
        for folder in folders where !folder.contains("node_modules") { try files.deleteDirectory(at: root + "/" + folder) }
        for (index, path) in ["skills/x/node_modules/package/incoming.js", "skills/x/node_modules", "skills/x"].enumerated() {
            let incoming = base + "/incoming-\(index)"
            try files.createDirectory(at: incoming)
            try native.initRepository(at: incoming)
            try files.writeFile(at: incoming + "/" + path, content: "incoming fixture\n")
            try native.runOrThrow(["-C", incoming, "add", "--force", "--all"], in: nil)
            try native.runOrThrow(["-C", incoming, "commit", "-m", "incoming"], in: nil)
            try native.runOrThrow(["-C", root, "fetch", incoming, "HEAD"], in: nil)
            let revision = try native.runOrThrow(["-C", root, "rev-parse", "FETCH_HEAD"], in: nil)
                .stdout.trimmingCharacters(in: .newlines)
            XCTAssertThrowsError(try store.requireNoExcludedCollision(with: revision)) { error in
                XCTAssertEqual(error.localizedDescription,
                               "Sync paused so it won't overwrite skills/x/node_modules on this Mac. "
                               + "Another Mac already synced files there. Move or rename this folder, then sync again.")
            }
            XCTAssertEqual(try files.readFile(at: root + "/skills/x/node_modules/package/index.js"), "local dependency\n")
            XCTAssertFalse(native.isRebaseInProgress(at: root))
        }
        try assertLegacyDependencyUpdatesRemainAdmitted(root: root, store: store, native: native)
        XCTAssertEqual(try files.readData(at: trace + "-cached"), Data("node_modules/legacy.js\0".utf8),
                       "The replacement inventory must exclude ordinary tracked skill files")
    }

    private func assertLegacyDependencyUpdatesRemainAdmitted(root: String, store: StoreGitOperation,
                                                             native: GitService) throws {
        let legacy = root + "/node_modules/legacy.js"
        try files.writeFile(at: legacy, content: "already tracked dependency\n")
        try native.runOrThrow(["-C", root, "add", "--force", "node_modules/legacy.js"], in: nil)
        try native.runOrThrow(["-C", root, "commit", "-m", "legacy dependency"], in: nil)
        let subtree = "node_modules/untracked-package"
        try files.writeFile(at: root + "/" + subtree + "/deep/file.js", content: "local subtree\n")
        XCTAssertTrue(try store.excludedUntrackedPaths().contains(Data((subtree + "/").utf8)),
                      "An untracked subtree in a partly tracked excluded folder must be one receipt")
        let incoming = try native.commitSHA(at: root)
        XCTAssertNoThrow(try store.requireNoExcludedCollision(with: incoming),
                         "A folder receipt must not suppress its already tracked files")
        try files.deleteFile(at: legacy)
        try files.writeFile(at: legacy + "/generated.js", content: "protected local dependency\n")
        XCTAssertThrowsError(try store.requireNoExcludedCollision(with: incoming)) { error in
            XCTAssertEqual(error as? StoreUpdateError, .excludedLocalFile(path: "node_modules/legacy.js/generated.js"))
        }
        XCTAssertEqual(try files.readFile(at: legacy + "/generated.js"), "protected local dependency\n")
    }

    func testPartlyTrackedExcludedFoldersAdmitIncomingSiblingsAndProtectLocalFiles() throws {
        for folder in ["node_modules", ".env", ".venv"] {
            for hidden in [false, true] {
                for app in [false, true] {
                    do {
                        try assertPartlyTrackedFolder(folder: folder, hidden: hidden, app: app)
                    } catch {
                        XCTFail("\(folder), hidden=\(hidden), app=\(app): \(error)")
                    }
                }
            }
        }
    }

    private func assertPartlyTrackedFolder(folder: String, hidden: Bool, app: Bool) throws {
        let prefix = "skills/x/" + folder
        let local = prefix + "/new.js"
        let incoming = prefix + "/other.js"
        let legacy = prefix + "/legacy.js"
        let fixture = try ExcludedFileCollisionFixture(path: local, hidden: hidden, localCommit: app,
                                                       incomingPath: incoming, legacyPath: legacy)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let git = fixture.git
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: git), lockPath: fixture.root + "/sync.lock")
        if app {
            guard case .synced = try engine.sync(root: fixture.storeB, message: "sibling", credential: nil,
                                                 context: fixture.context) else { return XCTFail("Sibling must sync") }
        } else {
            XCTAssertTrue(git.isWorktreeClean(at: fixture.storeB))
            guard case .fastForwarded = try git.fastForwardOnly(at: fixture.storeB, credential: nil)
            else { return XCTFail("Sibling must fast-forward") }
        }
        XCTAssertEqual(try files.readData(at: fixture.storeB + "/" + incoming), fixture.remoteBytes)
        XCTAssertEqual(try files.readData(at: fixture.storeB + "/" + local), fixture.localBytes)
        XCTAssertEqual(try files.readData(at: fixture.storeB + "/" + legacy), Data([5, 255]))
        let unpublished = try git.runData(["--git-dir", fixture.remote, "show", "main:" + local], in: nil)
        XCTAssertNotEqual(unpublished.exit, 0, "The new local excluded file must not reach the remote")
        _ = try git.pullRebase(at: fixture.storeA, credential: nil)
        try files.writeData(at: fixture.storeA + "/" + local, data: fixture.remoteBytes)
        try git.runOrThrow(["-C", fixture.storeA, "add", "--force", "--", local], in: nil)
        try git.runOrThrow(["-C", fixture.storeA, "commit", "-m", "older writer's colliding file"], in: nil)
        try git.push(at: fixture.storeA, credential: nil)
        let before = try git.headSHA(at: fixture.storeB)
        XCTAssertThrowsError(try git.fastForwardOnly(at: fixture.storeB, credential: nil)) { error in
            XCTAssertEqual(error as? StoreUpdateError, .excludedLocalFile(path: local))
        }
        XCTAssertEqual(try git.headSHA(at: fixture.storeB), before)
        XCTAssertEqual(try files.readData(at: fixture.storeB + "/" + local), fixture.localBytes)
        XCTAssertFalse(git.isRebaseInProgress(at: fixture.storeB))
    }

    func testLegacyDependencyInventoryGitRunsStayBoundedAsTheIndexGrows() throws {
        var counts: [Int] = []
        for count in [1, 2048] {
            let root = base + "/legacy-inventory-\(count)"
            let native = TestPaths.git
            try files.createDirectory(at: root)
            try native.initRepository(at: root)
            for index in 0..<count {
                let path = "node_modules/package-with-a-long-legacy-name-\(index)/dist/nested/legacy-output-for-inventory.js"
                try files.writeFile(at: root + "/" + path, content: "legacy dependency\n")
            }
            try native.runOrThrow(["-C", root, "add", "--force", "--", "node_modules"], in: nil)
            try native.runOrThrow(["-C", root, "commit", "-m", "older build's dependency tree"], in: nil)
            try files.writeFile(at: root + "/node_modules/new-package/output.js", content: "new local dependency\n")
            let trace = base + "/legacy-inventory-\(count)-trace"
            let recording = try inventoryRecordingGit(trace: trace)
            let store = try recording.storeOperation(at: root)
            try files.writeFile(at: trace + "-calls", content: "")
            XCTAssertEqual(try store.excludedUntrackedPaths(), [Data("node_modules/new-package/".utf8)])
            let calls = try files.readFile(at: trace + "-calls").split(separator: "\n").count
            counts.append(calls)
            XCTAssertLessThanOrEqual(calls, 4, "Unchanged indexed files must not become batches of pathspecs")
            let replaced = "node_modules/package-with-a-long-legacy-name-0/dist/nested/legacy-output-for-inventory.js"
            try files.deleteFile(at: root + "/" + replaced)
            try files.writeFile(at: root + "/" + replaced + "/generated.js", content: "protected local child\n")
            try files.writeFile(at: trace + "-calls", content: "")
            XCTAssertTrue(try store.excludedUntrackedPaths().contains(Data((replaced + "/generated.js").utf8)))
            XCTAssertLessThanOrEqual(try files.readFile(at: trace + "-calls").split(separator: "\n").count, 4)
            XCTAssertThrowsError(try store.requireNoExcludedCollision(with: native.commitSHA(at: root))) { error in
                XCTAssertEqual(error as? StoreUpdateError, .excludedLocalFile(path: replaced + "/generated.js"))
            }
        }
        XCTAssertEqual(counts.first, counts.last, "The number of inventory git runs must not grow with the legacy index")
    }

    private func inventoryRecordingGit(trace: String) throws -> GitService {
        let executable = base + "/inventory-git"
        try files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            printf 'git\\n' >> '\(trace)-calls'
            is_inventory() {
                \(FakeGitScript.skipGlobalOptions)
                [ "$1" = ls-files ] || return 1
                case "$*" in *--ignored*) return 0 ;; *) return 1 ;; esac
            }
            is_cached() {
                \(FakeGitScript.skipGlobalOptions)
                [ "$1" = diff ] || return 1
                case "$*" in *--diff-filter=D*) return 0 ;; *) return 1 ;; esac
            }
            if is_cached "$@"; then
                /usr/bin/git "$@" > '\(trace)-cached'
                result=$?
                cat '\(trace)-cached'
                exit "$result"
            fi
            if is_inventory "$@"; then
                /usr/bin/git "$@" > '\(trace)'
                result=$?
                cat '\(trace)'
                exit "$result"
            fi
            exec /usr/bin/git "$@"
            """ + "\n")
        return GitService(askpassHelperPath: base + "/inventory-askpass", executablePath: executable)
    }

    func testIncomingTrackedExcludedFilesPauseBeforeAppWritesAndResumeAfterMovingThem() throws {
        try assertFilesystemEquivalentIncomingNames()
        try assertHardLinksRemainDistinctEntries()
        try assertIndexedNestedRepositoryReplacementIsProtected()
        try assertUnchangedLegacyEntryProtectsLocalFolderReplacement()
        for hidden in [false, true] {
            for path in ExcludedFileCollisionFixture.paths {
                do {
                    try assertIncomingExcludedCollision(path: path, hidden: hidden)
                } catch {
                    XCTFail("\(path), skill ignores=\(hidden): \(error)")
                }
            }
        }
    }

    private func assertHardLinksRemainDistinctEntries() throws {
        for local in ["skills/x/.env", "skills/x/node_modules/pkg/cache"] {
            let fixture = try ExcludedFileCollisionFixture(path: local, hidden: true, localCommit: true,
                                                           incomingPath: "skills/x/ordinary.txt")
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            let linked = fixture.storeB + "/skills/x/ordinary.txt"
            XCTAssertEqual(link(fixture.storeB + "/" + local, linked), 0)
            try fixture.git.runOrThrow(["-C", fixture.storeB, "add", "--", "skills/x/ordinary.txt"], in: nil)
            try fixture.git.runOrThrow(["-C", fixture.storeB, "commit", "-m", "hard linked ordinary entry"], in: nil)
            try fixture.git.fetch(at: fixture.storeB, credential: nil)
            let operation = try fixture.git.storeOperation(at: fixture.storeB)
            XCTAssertNoThrow(try operation.requireNoExcludedCollision(with: "FETCH_HEAD"),
                             "R8: distinct hard-link directory entries cannot pause sync")
            XCTAssertEqual(try fixture.files.readData(at: fixture.storeB + "/" + local), fixture.localBytes)
        }
    }

    private func assertFilesystemEquivalentIncomingNames() throws {
        for (local, incoming) in [("skills/x/.env", "skills/x/.ENV"),
                                  ("skills/x/caf\u{00E9}/.env", "skills/x/cafe\u{0301}/.env"),
                                  ("skills/x/.env.ss", "skills/x/.env.ß"),
                                  ("skills/x/.env.σ", "skills/x/.env.ς"),
                                  ("skills/x/.env.secret", "skills/x/.env.ſecret"),
                                  ("skills/x/.env.fi", "skills/x/.env.ﬁ")] {
            let fixture = try ExcludedFileCollisionFixture(path: local, hidden: true, localCommit: true,
                                                           incomingPath: incoming)
            defer { try? fixture.files.deleteDirectory(at: fixture.root) }
            XCTAssertEqual(fixture.files.fileIdentity(at: fixture.storeB + "/" + local, followingLinks: false),
                           fixture.files.fileIdentity(at: fixture.storeB + "/" + incoming, followingLinks: false),
                           "These spellings identify the same protected destination")
            let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: fixture.git),
                                    lockPath: fixture.root + "/sync.lock")
            XCTAssertThrowsError(try engine.sync(root: fixture.storeB, message: "equivalent name", credential: nil,
                                                 context: fixture.context))
            XCTAssertEqual(try fixture.files.readData(at: fixture.storeB + "/" + local), fixture.localBytes)
            XCTAssertEqual(try fixture.git.headSHA(at: fixture.storeB), fixture.beforeHead)
        }
    }

    private func assertIndexedNestedRepositoryReplacementIsProtected() throws {
        let path = "skills/x/node_modules/b/.env"
        let fixture = try ExcludedFileCollisionFixture(path: path, hidden: true, localCommit: true,
            legacyPath: "skills/x/node_modules/b", replaceLegacyWithFolder: true, nestedReplacement: true)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: fixture.git),
                                lockPath: fixture.root + "/sync.lock")
        XCTAssertThrowsError(try engine.sync(root: fixture.storeB, message: "type replacement", credential: nil,
                                             context: fixture.context))
        XCTAssertEqual(try fixture.files.readData(at: fixture.storeB + "/" + path), fixture.localBytes)
        XCTAssertTrue(fixture.files.directoryExists(at: fixture.storeB + "/skills/x/node_modules/b/.git"))
        let remote = try fixture.git.runData(["--git-dir", fixture.remote, "show", "main:" + path], in: nil)
        XCTAssertEqual(remote.stdout, fixture.remoteBytes, "The local protected child must never be published")
        XCTAssertNotEqual(remote.stdout, fixture.localBytes)
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
    }

    private func assertUnchangedLegacyEntryProtectsLocalFolderReplacement() throws {
        let fixture = try ExcludedFileCollisionFixture(path: "skills/x/.env/local.txt", hidden: true, localCommit: true,
            incomingPath: "skills/x/unrelated.txt", legacyPath: "skills/x/.env", replaceLegacyWithFolder: true)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: fixture.git),
                                lockPath: fixture.root + "/sync.lock")
        XCTAssertThrowsError(try engine.sync(root: fixture.storeB, message: "local replacement", credential: nil,
                                             context: fixture.context))
        XCTAssertTrue(fixture.files.directoryExists(at: fixture.storeB + "/skills/x/.env"))
        XCTAssertEqual(try fixture.files.readData(at: fixture.storeB + "/" + fixture.path), fixture.localBytes)
        let remote = try fixture.git.runData(["--git-dir", fixture.remote, "show", "main:skills/x/.env"], in: nil)
        XCTAssertEqual(remote.stdout, Data([5, 255]), "The existing remote entry remains unchanged")
        XCTAssertFalse(fixture.git.isRebaseInProgress(at: fixture.storeB))
    }

    private func assertIncomingExcludedCollision(path: String, hidden: Bool) throws {
        let fixture = try ExcludedFileCollisionFixture(path: path, hidden: hidden, localCommit: true)
        defer { try? fixture.files.deleteDirectory(at: fixture.root) }
        let engine = SyncEngine(gitService: AllowlistedRemoteGit(wrapping: fixture.git),
                                lockPath: fixture.root + "/sync.lock")
        var prepared = false
        XCTAssertThrowsError(try engine.sync(root: fixture.storeB, message: "collision", credential: nil,
            context: fixture.context, prepare: { _ in prepared = true })) { error in
            XCTAssertEqual(error.localizedDescription, fixture.message)
        }
        XCTAssertFalse(prepared, "An incoming collision must stop before app snapshot preparation")
        try fixture.assertUntouched()
        // Direct rebase callers must also protect the same excluded bytes.
        XCTAssertThrowsError(try fixture.git.pullRebase(at: fixture.storeB, credential: nil)) { error in
            XCTAssertEqual(error.localizedDescription, fixture.message)
        }
        try fixture.assertUntouched()
        let pending = "skills/x/pending.txt"
        try fixture.files.writeFile(at: fixture.storeB + "/" + pending, content: "uncommitted ordinary work\n")
        let beforeIndex = try fixture.files.readData(at: fixture.storeB + "/.git/index")
        XCTAssertThrowsError(try engine.inspectConflicts(root: fixture.storeB, credential: nil,
                                                        context: fixture.context)) { error in
            XCTAssertEqual(error.localizedDescription, fixture.message)
        }
        try fixture.assertUntouched()
        XCTAssertThrowsError(try engine.resolveConflicts(root: fixture.storeB,
            picks: [path: ResolutionPick(side: .thisMachine, expectedThis: fixture.localBytes,
                                         expectedOther: fixture.remoteBytes)],
            credential: nil, context: fixture.context)) { error in
            XCTAssertEqual(error.localizedDescription, fixture.message)
        }
        try fixture.assertUntouched()
        XCTAssertEqual(try fixture.files.readData(at: fixture.storeB + "/.git/index"), beforeIndex,
                       "Neither inspection nor resolution may stage the pending ordinary file")
        XCTAssertEqual(try fixture.files.readFile(at: fixture.storeB + "/" + pending), "uncommitted ordinary work\n")
        try fixture.moveLocalFile()
        guard case .synced = try engine.sync(root: fixture.storeB, message: "resume", credential: nil,
            context: fixture.context) else { return XCTFail("Moving the obstacle must allow sync") }
        try fixture.assertResumed()
    }
}
