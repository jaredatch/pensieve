import SwiftData
import XCTest
@testable import Pensieve

extension SyncBytePreservationTests {
    func testUnsafeReceiptsCannotHideNewStoreFilesOrDaemonChanges() throws {
        try NativeTestWork.run { [self] in
            for source in [".pensieve-retired-paths", ".gitattributes"] {
                let remote = base + "/remote.git"
                let git = try userGit("receipt-writer", remote: remote, skillRules: true)
                try seedRemote(git: git, remote: remote)
                let store = base + "/store"
                try git.clone(remote: remoteURL, into: store, credential: nil)
                let tracked = "skills/old/assets/legacy/tracked"
                try files.writeFile(at: store + "/" + tracked, content: "tracked before retirement")
                try git.stageAllAndCommit(at: store, message: "tracked child")
                let unsafe = ["skills", "skills/new", "manifest", "manifest/categories", ".pensieve-retired-paths",
                              ".gitattributes", ".gitignore", "outside", "skills/upper/sKiLl.Md", "SKILLS/mixed/SKILL.MD"]
                try files.writeFile(at: store + "/" + source,
                    content: receiptText(unsafe + ["skills/old/assets/legacy"]))
                try commitOlderReceipts(git: git, store: store, source: source)
                XCTAssertTrue(git.isWorktreeClean(at: store))
                let additions = ["skills/new/SKILL.md", "skills/upper/SKILL.md", "skills/mixed/SKILL.md", "outside/new"]
                for path in additions { try files.writeFile(at: store + "/" + path, content: "new file: " + path) }
                XCTAssertFalse(git.isWorktreeClean(at: store), "Unsafe receipts cannot hide unsynced files from the daemon")
                try git.retireConflictPath("skills/another/assets/legacy", at: store)
                try files.writeFile(at: store + "/" + tracked, content: "tracked update")
                let local = store + "/skills/old/assets/legacy/local"
                try files.writeFile(at: local, content: "stays local")
                let context = try makeContext()
                // Record the clone's launch ingest before the window adds its unsynced category.
                _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: store, context: context)
                context.insert(Pensieve.Category(name: "New receipt category"))
                try context.save()
                _ = try engine(git: git).sync(root: store, message: "unsafe receipts", credential: nil, context: context)
                let tree = try git.runOrThrow(["--git-dir", remote, "ls-tree", "-r", "--name-only", "main"], in: nil).stdout
                for path in additions + [".pensieve-retired-paths", ".gitattributes", ".gitignore", tracked] {
                    XCTAssertTrue(tree.split(separator: "\n").contains(Substring(path)), "Missing remote path: \(path)")
                }
                XCTAssertTrue(tree.contains("manifest/categories/"), "The manifest receipt must not hide a new category")
                XCTAssertEqual(try git.runData(["--git-dir", remote, "show", "main:" + tracked], in: nil).stdout,
                               Data("tracked update".utf8))
                XCTAssertFalse(tree.contains("skills/old/assets/legacy/local"))
                XCTAssertEqual(try files.readFile(at: local), "stays local")
                XCTAssertEqual(try git.runData(["--git-dir", remote, "show", "main:.pensieve-retired-paths"], in: nil).stdout,
                               Data(receiptText(["skills/another/assets/legacy", "skills/old/assets/legacy"]).utf8))
                try files.deleteDirectory(at: base)
                try files.createDirectory(at: base)
            }
        }
    }

    func testPulledUnsafeReceiptDropsOnFollowingSyncAndOlderReplayConverges() throws {
        try NativeTestWork.run { [self] in
            let remote = base + "/remote.git"
            let git = try userGit("receipt-writer", remote: remote, skillRules: true)
            try seedRemote(git: git, remote: remote)
            let older = base + "/older", current = base + "/current"
            try git.clone(remote: remoteURL, into: older, credential: nil)
            // Keep the union-merged file in the base, so the drop is a content edit, never a deletion.
            try files.writeFile(at: older + "/.pensieve-retired-paths", content: "")
            try commitOlderReceipts(git: git, store: older)
            try git.push(at: older, credential: nil)
            try git.clone(remote: remoteURL, into: current, credential: nil)
            let context = try makeContext()
            let unsafe = receiptText(["skills"])
            for replay in 0..<2 {
                if replay > 0 { _ = try git.fastForwardOnly(at: older, credential: nil) }
                try files.writeFile(at: older + "/.pensieve-retired-paths", content: unsafe)
                try commitOlderReceipts(git: git, store: older)
                try git.push(at: older, credential: nil)
                _ = try engine(git: git).sync(root: current, message: "pull receipt", credential: nil, context: context)
                XCTAssertEqual(try files.readFile(at: current + "/.pensieve-retired-paths"), unsafe)
                let path = "skills/new-\(replay)/SKILL.md"
                try files.writeFile(at: current + "/" + path, content: "new skill")
                // Exercise the first operation after arrival, before the next prepare can clean the file.
                XCTAssertFalse(git.isWorktreeClean(at: current))
                XCTAssertTrue(try git.stageAllAndCommit(at: current, message: "stage after receipt arrival"))
                XCTAssertEqual(try git.runData(["-C", current, "show", "HEAD:" + path], in: nil).stdout,
                               Data("new skill".utf8))
                _ = try engine(git: git).sync(root: current, message: "drop receipt", credential: nil, context: context)
                let receipts = try git.runData(["--git-dir", remote, "show", "main:.pensieve-retired-paths"], in: nil)
                XCTAssertEqual(receipts.exit, 0, "An all-unsafe file remains tracked")
                XCTAssertEqual(receipts.stdout, Data())
            }
            let stable = try git.runOrThrow(["--git-dir", remote, "rev-parse", "main:.pensieve-retired-paths"], in: nil).stdout
            let olderContext = try makeContext()
            for _ in 0..<2 {
                for (store, context) in [(older, olderContext), (current, context)] {
                    _ = try engine(git: git).sync(root: store, message: "stable receipt", credential: nil, context: context)
                    XCTAssertEqual(try git.runOrThrow(["--git-dir", remote, "rev-parse", "main:.pensieve-retired-paths"],
                                                     in: nil).stdout, stable)
                }
            }
        }
    }

    func testDroppingAllUnsafeReceiptsUnionsConcurrentValidReceipt() throws {
        try NativeTestWork.run { [self] in
            let remote = base + "/remote.git"
            let git = try userGit("receipt-writer", remote: remote, skillRules: true)
            try seedRemote(git: git, remote: remote)
            let other = base + "/other", current = base + "/current"
            try git.clone(remote: remoteURL, into: other, credential: nil)
            try files.writeFile(at: other + "/.pensieve-retired-paths", content: receiptText(["skills"]))
            try commitOlderReceipts(git: git, store: other)
            try git.push(at: other, credential: nil)
            try git.clone(remote: remoteURL, into: current, credential: nil)
            try StoreIgnoreRules.prepare(at: current, files: files)
            XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: current + "/.pensieve-retired-paths"), .regular)
            XCTAssertEqual(try files.readData(at: current + "/.pensieve-retired-paths"), Data())
            try git.stageAllAndCommit(at: current, message: "drop last unsafe receipt")
            try files.writeFile(at: other + "/.pensieve-retired-paths",
                                content: receiptText(["skills", "skills/safe/assets/legacy"]))
            try commitOlderReceipts(git: git, store: other)
            try git.push(at: other, credential: nil)
            guard case .synced = try engine(git: git).sync(root: current, message: "drop while another Mac retires",
                credential: nil, context: makeContext()) else { return XCTFail("Receipt edits must union without a conflict") }
            let merged = try files.readFile(at: current + "/.pensieve-retired-paths")
            XCTAssertTrue(merged.contains(receiptText(["skills/safe/assets/legacy"])))
            // The other writer still carried the unsafe line. Like any pulled receipt, the
            // union's stale line is inert now and is cleaned by the following prepare.
            _ = try engine(git: git).sync(root: current, message: "clean union receipts", credential: nil,
                                        context: makeContext())
            XCTAssertEqual(try git.runData(["--git-dir", remote, "show", "main:.pensieve-retired-paths"], in: nil).stdout,
                           Data(receiptText(["skills/safe/assets/legacy"]).utf8))
        }
    }

    func testMalformedReceiptsStopSyncBeforePublishing() throws {
        try NativeTestWork.run { [self] in
            let remote = base + "/remote.git"
            let git = try userGit("receipt-writer", remote: remote, skillRules: true)
            try seedRemote(git: git, remote: remote)
            let before = try git.runOrThrow(["--git-dir", remote, "rev-parse", "main"], in: nil).stdout
            for source in [".gitattributes", ".pensieve-retired-paths"] {
                let encoded = "# Pensieve retired path: " + Data("skills/a/b".utf8).base64EncodedString()
                let badLines = ["# Pensieve retired path: %%%\n", receiptText(["skills/x/../bad"])]
                    + ["\r", "\u{0085}", "\u{2028}", "\u{2029}"].map { encoded + $0 + "junk\n" }
                for badLine in badLines {
                    let store = base + "/malformed-" + UUID().uuidString
                    try git.clone(remote: remoteURL, into: store, credential: nil)
                    let manifestBefore = try files.readData(at: store + "/manifest/manifest.yaml")
                    try files.writeFile(at: store + "/" + source, content: badLine)
                    XCTAssertThrowsError(try engine(git: git).sync(root: store, message: "malformed receipt",
                        credential: nil, context: makeContext())) {
                        XCTAssertTrue($0.localizedDescription.hasPrefix(
                            "Sync stopped because a retirement receipt names an unsafe store path"))
                    }
                    XCTAssertEqual(try files.readFile(at: store + "/" + source), badLine)
                    XCTAssertEqual(try files.readData(at: store + "/manifest/manifest.yaml"), manifestBefore)
                    XCTAssertEqual(try git.runOrThrow(["--git-dir", remote, "rev-parse", "main"], in: nil).stdout, before)
                }
            }
        }
    }

    private func receiptText(_ paths: [String]) -> String {
        paths.map { "# Pensieve retired path: " + Data($0.utf8).base64EncodedString() + "\n" }.joined()
    }

    private func commitOlderReceipts(git: GitService, store: String, source: String = ".pensieve-retired-paths") throws {
        // Native staging models another writer; the current receipt policy must not sanitize the input fixture.
        try git.runOrThrow(["-C", store, "add", "--force", "--", source], in: nil)
        try git.runOrThrow(["-C", store, "commit", "-m", "older receipt writer"], in: nil)
    }
}
