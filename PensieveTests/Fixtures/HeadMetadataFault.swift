import Foundation
@testable import Pensieve

/// Corrupts only git metadata, leaving the library readable so a real writer must rebuild it.
/// The returned restoration is idempotent, allowing the fixture's subsequent sync to use git.
enum HeadMetadataFault: String, CaseIterable {
    case malformed, missingGitdir, refChain

    func apply(root: String) throws -> () throws -> Void {
        let files = FileService()
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
