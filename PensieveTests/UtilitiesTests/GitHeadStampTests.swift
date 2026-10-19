import Foundation
import XCTest
@testable import Pensieve

final class GitHeadStampTests: XCTestCase {
    var base = ""
    let files = FileService()

    override func setUpWithError() throws {
        base = TestTemporaryDirectory.path + "HeadStamp-" + UUID().uuidString
        try files.createDirectory(at: base)
    }

    override func tearDownWithError() throws { try files.deleteDirectory(at: base) }

    func testRepositoryShapesAndHeadFormsMatchGit() throws {
        try NativeTestWork.run { [self] in
            for format in ["sha1", "sha256"] {
                for shape in HeadRepository.Shape.allCases {
                    let fixture = try HeadRepository(base: base + "/" + format + shape.rawValue, shape: shape, format: format)
                    try assertOracle(fixture, label: "\(shape): loose")
                    _ = try fixture.git(["pack-refs", "--all", "--prune"])
                    try assertOracle(fixture, label: "\(shape): packed")
                    try files.writeFile(at: fixture.metadata + "/HEAD", content: fixture.oid + "\n")
                    try assertOracle(fixture, label: "\(shape): detached")
                    try files.writeFile(at: fixture.metadata + "/HEAD", content: "ref: refs/heads/unborn\n")
                    try assertOracle(fixture, fallback: .unborn, label: "\(shape): unborn")
                }
            }
        }
    }

    func testGeneratedHeadAndLooseRefTextMatchesGit() throws {
        try NativeTestWork.run { [self] in
            let f = try HeadRepository(base: base, shape: .folder)
            for ending in ["\n", "\r\n", ""] {
                for body in ["ref: refs/heads/main", "ref:\trefs/heads/main", "ref:  refs/heads/main",
                             "ref: refs/heads/main ", "ref: refs/heads/unborn", f.oid, f.oid.uppercased(), f.oid + " "] {
                    try files.writeFile(at: f.metadata + "/HEAD", content: body + ending)
                    try assertOracle(f, fallback: body.contains("unborn") ? .unborn : .unreadable,
                                     label: "HEAD \((body + ending).debugDescription)")
                }
            }
            for body in ["", "\n", " " + f.oid, " ref: refs/heads/main\n", "ref: refs/heads/main\nextra\n",
                         "ref: refs/heads/../main\n", "not a head\n", f.oid + "X\n", f.oid + "\nextra\n",
                         String(repeating: "a", count: 64), f.oid + "\0extra"] {
                try files.writeFile(at: f.metadata + "/HEAD", content: body)
                try assertOracle(f, label: "HEAD \(body.debugDescription)")
            }
            try files.writeFile(at: f.metadata + "/HEAD", content: "ref: refs/heads/main\n")
            for ending in ["\n", "\r\n", ""] {
                for body in [f.oid, f.oid.uppercased(), f.oid + " ", " " + f.oid, "", "bad", f.oid + "\nextra"] {
                    try files.writeFile(at: f.common + "/refs/heads/main", content: body + ending)
                    try assertOracle(f, label: "loose \((body + ending).debugDescription)")
                }
            }
        }
    }

    func testGeneratedGitdirAndCommondirTextMatchesGit() throws {
        try NativeTestWork.run { [self] in
            for shape in [HeadRepository.Shape.relativeFile, .absoluteFile, .worktree] {
                let f = try HeadRepository(base: base + "/" + shape.rawValue, shape: shape)
                let path = shape == .worktree ? f.metadata + "/commondir" : f.root + "/.git"
                let original = try files.readFile(at: path).trimmingCharacters(in: .newlines)
                for ending in ["\n", "\r\n", "", "\n\n"] {
                    for body in [original, " " + original, original + " ", "", ".", "missing", "gitdir: missing"] {
                        try files.writeFile(at: path, content: body + ending)
                        try assertOracle(f, label: "\(shape) \((body + ending).debugDescription)")
                    }
                }
                try files.writeFile(at: path, content: original + "\n")
                if shape == .worktree {
                    try files.writeFile(at: path, content: f.common + "\n")
                    try assertOracle(f, label: "absolute commondir")
                }
            }
        }
    }

    func testGeneratedPackedRefsTextMatchesGit() throws {
        try NativeTestWork.run { [self] in
            let f = try HeadRepository(base: base, shape: .worktree)
            try files.deleteFile(at: f.common + "/refs/heads/main")
            let header = "# pack-refs with: peeled fully-peeled sorted \n"
            for ending in ["\n", "\r\n", ""] {
                for prefix in ["", header] {
                    for record in [f.oid + " refs/heads/main", f.oid + "\trefs/heads/main",
                                   f.oid + "  refs/heads/main", f.oid + " refs/heads/main ", "bad"] {
                        let text = prefix + record + ending
                        try files.writeFile(at: f.common + "/packed-refs", content: text)
                        try assertOracle(f, label: "packed \(text.debugDescription)")
                    }
                }
            }
            for text in ["", header, f.oid + " refs/heads/other\n", header + f.oid + " refs/heads/main\n^" + f.oid + "\n",
                         "bad\n" + f.oid + " refs/heads/main\n", "\n" + f.oid + " refs/heads/main\n",
                         "# hello\n", f.oid + " refs/heads/main\n^bad\n",
                         header + "bad\n" + f.oid + " refs/heads/main\n",
                         header + f.oid + " refs/heads/main\nbad\n"] {
                try files.writeFile(at: f.common + "/packed-refs", content: text)
                let absent = ["", header, f.oid + " refs/heads/other\n"].contains(text)
                try assertOracle(f, fallback: absent ? .unborn : .unreadable, label: "packed \(text.debugDescription)")
            }
            try files.writeFile(at: f.common + "/packed-refs", content: "malformed\n")
            try files.writeFile(at: f.common + "/refs/heads/main", content: f.oid + "\n")
            try assertOracle(f, label: "malformed packed refs with a loose ref")
            let old = String(repeating: "a", count: 40)
            try files.writeFile(at: f.common + "/packed-refs", content: old + " refs/heads/main\n")
            try assertOracle(f, label: "loose ref wins over a different packed OID")
        }
    }

    func testAbsentRepositoryAndUnresolvedMetadataStayDistinct() throws {
        try NativeTestWork.run { [self] in
            XCTAssertEqual(GitHeadStamp().state(root: base), .noRepository)
            let f = try HeadRepository(base: base, shape: .relativeFile)
            try files.writeFile(at: f.root + "/.git", content: "gitdir: missing\n")
            try assertOracle(f, label: "missing gitdir")
            try files.writeFile(at: f.root + "/.git", content: "gitdir: ../metadata\n")
            try files.writeFile(at: f.metadata + "/refs/heads/alias", content: "ref: refs/heads/main\n")
            try files.writeFile(at: f.metadata + "/HEAD", content: "ref: refs/heads/alias\n")
            XCTAssertEqual(try f.git(["rev-parse", "--verify", "HEAD"]), f.oid)
            XCTAssertEqual(GitHeadStamp().state(root: f.root), .unreadable,
                           "Ref chains deliberately force ingestion even when git can resolve them")
        }
    }

    func assertOracle(_ fixture: HeadRepository, fallback: GitHeadStamp.State = .unreadable,
                      label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let oracle = try TestPaths.git.run(["rev-parse", "--verify", "HEAD"], in: fixture.root)
        let expected = oracle.exit == 0
            ? GitHeadStamp.State.resolved(oracle.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) : fallback
        XCTAssertEqual(GitHeadStamp().state(root: fixture.root), expected,
                       label + ": " + oracle.stderr, file: file, line: line)
    }
}

/// Real repository layouts; git itself supplies the expected OID, never the stamp reader.
struct HeadRepository {
    enum Shape: String, CaseIterable { case folder, linkedFolder, relativeFile, absoluteFile, worktree, separate }
    let root: String
    let metadata: String
    let common: String
    let oid: String

    init(base: String, shape: Shape, format: String = "sha1") throws {
        let files = FileService(), git = TestPaths.git
        root = base + "/store"
        try files.createDirectory(at: base)
        let initial = shape == .worktree ? base + "/primary" : root
        var arguments = ["init", "--initial-branch=main", "--object-format=" + format]
        if shape == .separate { arguments += ["--separate-git-dir", base + "/metadata"] }
        _ = try git.runOrThrow(arguments + [initial], in: nil)
        _ = try git.runOrThrow(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                               "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "seed"], in: initial)
        if shape == .worktree {
            _ = try git.runOrThrow(["checkout", "--detach"], in: initial)
            _ = try git.runOrThrow(["worktree", "add", root, "main"], in: initial)
        } else if [.linkedFolder, .relativeFile, .absoluteFile].contains(shape) {
            try FileManager.default.moveItem(atPath: root + "/.git", toPath: base + "/metadata")
            if shape == .linkedFolder {
                try files.createSymlink(at: root + "/.git", pointingTo: base + "/metadata")
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
