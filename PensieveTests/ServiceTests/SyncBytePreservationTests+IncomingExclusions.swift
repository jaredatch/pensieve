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
        let folders = ["node_modules", "skills/x/node_modules", "skills/new/node_modules"]
        for folder in folders {
            for name in ["package/index.js", "package/deep/other.js"] {
                try files.writeFile(at: root + "/" + folder + "/" + name, content: "local dependency\n")
            }
        }
        try files.writeFile(at: root + "/skills/x/.env", content: "local env\n")
        let trace = base + "/inventory-output"
        let recording = try inventoryRecordingGit(trace: trace)
        let store = try recording.storeOperation(at: root)
        let inventory = try store.excludedUntrackedPaths()
        XCTAssertEqual(Set(inventory), Set((folders + ["skills/x/.env"]).map { Data($0.utf8) }))
        let nativeInventory = try files.readData(at: trace).split(separator: 0)
        XCTAssertFalse(nativeInventory.isEmpty)
        XCTAssertTrue(nativeInventory.allSatisfy { $0.last == 0x2F },
                      "Git must report dependency directories, never walk their files")
        try files.deleteFile(at: root + "/skills/x/.env")
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
                XCTAssertEqual(error as? StoreUpdateError, .excludedLocalFile(path: "skills/x/node_modules"))
            }
            XCTAssertEqual(try files.readFile(at: root + "/skills/x/node_modules/package/index.js"), "local dependency\n")
            XCTAssertFalse(native.isRebaseInProgress(at: root))
        }
        try assertLegacyDependencyUpdatesRemainAdmitted(root: root, store: store, native: native)
    }

    private func assertLegacyDependencyUpdatesRemainAdmitted(root: String, store: StoreGitOperation,
                                                             native: GitService) throws {
        let legacy = root + "/node_modules/legacy.js"
        try files.writeFile(at: legacy, content: "already tracked dependency\n")
        try native.runOrThrow(["-C", root, "add", "--force", "node_modules/legacy.js"], in: nil)
        try native.runOrThrow(["-C", root, "commit", "-m", "legacy dependency"], in: nil)
        let incoming = try native.commitSHA(at: root)
        XCTAssertNoThrow(try store.requireNoExcludedCollision(with: incoming),
                         "A folder receipt must not suppress its already tracked files")
        try files.deleteFile(at: legacy)
        try files.writeFile(at: legacy + "/generated.js", content: "protected local dependency\n")
        XCTAssertThrowsError(try store.requireNoExcludedCollision(with: incoming)) { error in
            XCTAssertEqual(error as? StoreUpdateError, .excludedLocalFile(path: "node_modules"))
        }
        XCTAssertEqual(try files.readFile(at: legacy + "/generated.js"), "protected local dependency\n")
    }

    private func inventoryRecordingGit(trace: String) throws -> GitService {
        let executable = base + "/inventory-git"
        try files.writeExecutableFile(at: executable, content: """
            #!/bin/sh
            is_inventory() {
                \(FakeGitScript.skipGlobalOptions)
                [ "$1" = ls-files ] || return 1
                case "$*" in *--ignored*) return 0 ;; *) return 1 ;; esac
            }
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
        try fixture.moveLocalFile()
        guard case .synced = try engine.sync(root: fixture.storeB, message: "resume", credential: nil,
            context: fixture.context) else { return XCTFail("Moving the obstacle must allow sync") }
        try fixture.assertResumed()
    }
}
