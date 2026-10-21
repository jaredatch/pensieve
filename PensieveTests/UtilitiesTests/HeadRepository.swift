import Foundation
@testable import Pensieve

/// Real repository layouts; git itself supplies the expected OID, never the stamp reader.
struct HeadRepository {
    enum Shape: String, CaseIterable {
        case folder, linkedFolder, linkedFile, relativeFile, absoluteFile, worktree, separate, filtered
    }
    let root: String
    let metadata: String
    let common: String
    let oid: String

    init(base: String, shape: Shape, format: String = "sha1", refFormat: String = "files") throws {
        let files = FileService(), git = TestPaths.git
        root = base + "/store"
        try files.createDirectory(at: base)
        let initial = [.worktree, .filtered].contains(shape) ? base + "/primary" : root
        var arguments = ["init", "--initial-branch=main", "--object-format=" + format]
        if refFormat != "files" { arguments += ["--ref-format=" + refFormat] }
        if shape == .separate { arguments += ["--separate-git-dir", base + "/metadata"] }
        _ = try git.runOrThrow(arguments + [initial], in: nil)
        _ = try git.runOrThrow(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                               "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "seed"], in: initial)
        if shape == .filtered {
            _ = try git.runOrThrow(["config", "uploadpack.allowFilter", "true"], in: initial)
            _ = try git.runOrThrow(["clone", "--filter=blob:none", "file://" + initial, root], in: nil)
        } else if shape == .worktree {
            _ = try git.runOrThrow(["checkout", "--detach"], in: initial)
            _ = try git.runOrThrow(["worktree", "add", root, "main"], in: initial)
        } else if [.linkedFolder, .linkedFile, .relativeFile, .absoluteFile].contains(shape) {
            try FileManager.default.moveItem(atPath: root + "/.git", toPath: base + "/metadata")
            if shape == .linkedFolder {
                try files.createSymlink(at: root + "/.git", pointingTo: base + "/metadata")
            } else if shape == .linkedFile {
                try files.writeFile(at: base + "/gitdir", content: "gitdir: " + base + "/metadata\n")
                try files.createSymlink(at: root + "/.git", pointingTo: base + "/gitdir")
            } else {
                let target = shape == .relativeFile ? "../metadata" : base + "/metadata"
                try files.writeFile(at: root + "/.git", content: "gitdir: " + target + "\n")
            }
        }
        metadata = try git.runOrThrow(["rev-parse", "--absolute-git-dir"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        common = try git.runOrThrow(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        oid = try git.runOrThrow(["rev-parse", "--verify", "HEAD"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func git(_ arguments: [String]) throws -> String {
        try TestPaths.git.runOrThrow(arguments, in: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
