import SwiftData
import XCTest
@testable import Pensieve

extension SyncBytePreservationTests {
    func testUntrackedSecretsAndBuildLitterStayLocalWithAndWithoutSkillIgnores() throws {
        for hidden in [false, true] {
            for pathStaging in [false, true] {
                try assertExcludedRoundTrip(hidden: hidden, pathStaging: pathStaging)
            }
        }
    }

    private func assertExcludedRoundTrip(hidden: Bool, pathStaging: Bool) throws {
        let name = "\(hidden)-\(pathStaging)"
        let remote = base + "/excluded-\(name).git"
        let git = try userGit("excluded-\(name)", remote: remote, skillRules: true)
        try seedRemote(git: git, remote: remote)
        let store = base + "/excluded-store-\(name)"
        try git.clone(remote: remoteURL, into: store, credential: nil)
        let context = try exclusionContext(store: store)
        try files.writeFile(at: store + "/skills/safe/.gitignore", content: hidden ? "*\n" : "hidden.bin\n")
        let carried = ["skills/safe/hidden.bin", "skills/safe/nested/hidden.bin", "skills/safe/node_modules.txt",
                       "skills/safe/nested/.environment", "skills/safe/.env-folder/ordinary.bin"]
        for path in carried { try files.writeData(at: store + "/" + path, data: Data([0, 255, 1, 2])) }
        var excluded: [String: Data] = [:]
        for prefix in ["", "skills/safe/", "skills/safe/nested/"] {
            for name in [".env", ".env.local", "node_modules/package/index.js", ".DS_Store"] {
                let path = prefix + name
                let bytes = Data(("local fixture " + path).utf8)
                excluded[path] = bytes
                try files.writeData(at: store + "/" + path, data: bytes)
                if pathStaging { try git.stagePath(path, at: store) }
            }
        }
        // A directory path must not bypass the exclusions for its new children.
        if pathStaging { try git.stagePath("skills/safe", at: store) }
        XCTAssertEqual(try engine(git: git).sync(root: store, message: "safe skill", credential: nil,
            context: context), .synced(pushed: true, warnings: []))
        let tree = try git.runOrThrow(["--git-dir", remote, "ls-tree", "-r", "--name-only", "main"], in: nil)
        let paths = Set(tree.stdout.split(separator: "\n").map(String.init))
        for (path, bytes) in excluded {
            XCTAssertEqual(try files.readData(at: store + "/" + path), bytes, "Exclusion must not alter local bytes")
            XCTAssertFalse(paths.contains(path), "Remote leaked \(path), skill ignores=\(hidden), path staging=\(pathStaging)")
        }
        XCTAssertTrue(git.isWorktreeClean(at: store), "Only excluded untracked files must leave the daemon clean")
        XCTAssertFalse(try git.stageAllAndCommit(at: store, message: "excluded files stay local"))
        let fresh = base + "/excluded-fresh-\(name)"
        try git.clone(remote: remoteURL, into: fresh, credential: nil)
        for path in carried + ["skills/safe/SKILL.md", "skills/safe/.gitignore"] {
            XCTAssertTrue(paths.contains(path), "The skill's other ignored files must sync")
            XCTAssertEqual(try files.readData(at: fresh + "/" + path), try files.readData(at: store + "/" + path))
        }
        for path in excluded.keys { XCTAssertFalse(files.fileExists(at: fresh + "/" + path), path) }
    }

    func testAlreadyTrackedEnvKeepsSyncingWithoutDeletingEitherStore() throws {
        let remote = base + "/legacy-env.git"
        let git = try userGit("legacy-env", remote: remote, skillRules: true)
        try seedRemote(git: git, remote: remote)
        let store = base + "/legacy-store"
        try git.clone(remote: remoteURL, into: store, credential: nil)
        let context = try exclusionContext(store: store)
        _ = try engine(git: git).sync(root: store, message: "skill", credential: nil, context: context)
        let path = "skills/safe/.env"
        try files.writeFile(at: store + "/" + path, content: "older build fixture\n")
        // Seed an older build's tracked file through native git, independently of the new policy.
        try git.runOrThrow(["-C", store, "add", "--force", "--", path], in: nil)
        try git.runOrThrow(["-C", store, "commit", "-m", "older build tracked env"], in: nil)
        try git.push(at: store, credential: nil)
        let other = base + "/legacy-other"
        try git.clone(remote: remoteURL, into: other, credential: nil)
        let changed = Data([0, 255, 128, 13, 10])
        try files.writeData(at: store + "/" + path, data: changed)
        XCTAssertFalse(git.isWorktreeClean(at: store), "A tracked excluded name remains a pending change")
        try git.stagePath(path, at: store)
        XCTAssertEqual(try engine(git: git).sync(root: store, message: "legacy env changes", credential: nil,
            context: context), .synced(pushed: true, warnings: []))
        _ = try git.fastForwardOnly(at: other, credential: nil)
        let fresh = base + "/legacy-fresh"
        try git.clone(remote: remoteURL, into: fresh, credential: nil)
        let blob = try git.runData(["--git-dir", remote, "show", "main:" + path], in: nil)
        XCTAssertEqual(blob.exit, 0)
        XCTAssertEqual(blob.stdout, changed)
        for root in [store, other, fresh] { XCTAssertEqual(try files.readData(at: root + "/" + path), changed) }
        XCTAssertTrue(git.isWorktreeClean(at: store))
    }

    private func exclusionContext(store: String) throws -> ModelContext {
        try files.writeFile(at: store + "/skills/safe/SKILL.md",
                            content: "---\nname: Safe\ndescription: Safe fixture\n---\nbody\n")
        let context = try makeContext()
        context.insert(Skill(name: "Safe", skillDescription: "Safe fixture", directoryName: "safe"))
        try context.save()
        return context
    }
}
