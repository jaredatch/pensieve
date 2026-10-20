import Foundation
import XCTest
@testable import Pensieve

/// Changes only git metadata, leaving the library readable so a real writer must rebuild it.
/// The returned restoration is idempotent, allowing the fixture's subsequent sync to use git.
enum HeadMetadataFault: String, CaseIterable {
    case malformed, missingGitdir, refChain, reftable, unknownExtension

    func assertUnreadable(root: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(GitHeadStamp().state(root: root), .unreadable, file: file, line: line)
        if self == .unknownExtension {
            let oracle = try NativeTestWork.run { try TestPaths.git.run(["rev-parse", "--verify", "HEAD"], in: root) }
            XCTAssertNotEqual(oracle.exit, 0, file: file, line: line)
            XCTAssertTrue(oracle.stderr.contains("unknown repository extension"), oracle.stderr, file: file, line: line)
        }
    }

    func apply(root: String) throws -> () throws -> Void {
        let files = FileService()
        if self == .reftable {
            try NativeTestWork.run {
                _ = try TestPaths.git.runOrThrow(["refs", "migrate", "--ref-format=reftable"], in: root)
            }
            var restored = false
            return {
                if !restored {
                    try NativeTestWork.run {
                        _ = try TestPaths.git.runOrThrow(["refs", "migrate", "--ref-format=files"], in: root)
                    }
                    restored = true
                }
            }
        }
        if self == .unknownExtension {
            let path = root + "/.git/config", original = try files.readFile(at: path)
            try files.writeFile(at: path, content: original
                + "\n[core]\nrepositoryformatversion = 1\n[extensions]\nunknownExtension = true\n")
            return { try files.writeFile(at: path, content: original) }
        }
        if self == .missingGitdir {
            let saved = root + "-saved-metadata"
            try FileManager.default.moveItem(atPath: root + "/.git", toPath: saved)
            try files.writeFile(at: root + "/.git", content: "gitdir: missing-metadata\n")
            return {
                if files.directoryExists(at: saved) {
                    try files.deleteFile(at: root + "/.git")
                    try FileManager.default.moveItem(atPath: saved, toPath: root + "/.git")
                }
            }
        }
        let path = root + "/.git/HEAD"
        let original = try files.readFile(at: path)
        let alias = root + "/.git/refs/heads/fixture-alias"
        if self == .refChain {
            try files.writeFile(at: alias, content: original)
            try files.writeFile(at: path, content: "ref: refs/heads/fixture-alias\n")
        } else {
            try files.writeFile(at: path, content: "unreadable head\n")
        }
        return {
            try files.writeFile(at: path, content: original)
            if files.fileExists(at: alias) { try files.deleteFile(at: alias) }
        }
    }
}

extension IncompleteIngestFixture {
    func convertToLinkedWorktree() throws {
        _ = try git.runOrThrow(["checkout", "--detach"], in: app)
        let primary = base + "/primary"
        try FileManager.default.moveItem(atPath: app, toPath: primary)
        _ = try git.runOrThrow(["worktree", "add", app, "main"], in: primary)
    }
}

extension IncompleteIngestFixture {
    func configureReadableFormat(_ configuration: String) throws {
        if configuration == "plain" { return }
        if configuration == "sparse" {
            _ = try git.runOrThrow(["sparse-checkout", "init"], in: app)
            _ = try git.runOrThrow(["sparse-checkout", "disable"], in: app)
            return
        }
        let version = configuration == "v0" ? "0" : "1"
        _ = try git.runOrThrow(["config", "core.repositoryformatversion", version], in: app)
        for (key, value) in [("worktreeConfig", "true"), ("preciousObjects", "true"),
                             ("partialClone", "origin"), ("noop", "true")] {
            _ = try git.runOrThrow(["config", "extensions." + key, value], in: app)
        }
        let setting = version == "0" ? "unknownExtension" : "relativeWorktrees"
        _ = try git.runOrThrow(["config", "extensions." + setting, "true"], in: app)
    }
}
