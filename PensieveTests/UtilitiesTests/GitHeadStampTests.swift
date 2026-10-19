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
                    try assertOracle(fixture, label: "\(shape): unborn")
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
                    try assertOracle(f,
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
            let old = String(repeating: "a", count: 40)
            for packed in ["malformed\n", old + " refs/heads/main\n", old + " refs/heads/other\n"] {
                try files.writeFile(at: f.common + "/packed-refs", content: packed)
                try files.writeFile(at: f.common + "/refs/heads/main", content: f.oid + "\n")
                // show-ref reads the exact ref; rev-parse also opens packed refs during DWIM setup.
                let direct = try f.git(["show-ref", "--verify", "--hash", "refs/heads/main"])
                let observed = RebuildReadFileService()
                var reads: [String] = []
                observed.afterRead = { path in
                    let path = URL(fileURLWithPath: path).standardizedFileURL.path
                    reads.append(path)
                    if path == f.common + "/packed-refs", packed != "malformed\n" {
                        // Git publishes the packed snapshot before pruning the loose ref.
                        _ = try f.git(["pack-refs", "--all", "--prune"])
                    }
                }
                XCTAssertEqual(GitHeadStamp(fileService: observed).state(root: f.root), .resolved(direct))
                XCTAssertTrue(reads.contains(f.common + "/refs/heads/main"))
                XCTAssertFalse(reads.contains(f.common + "/packed-refs"), "A present loose ref must win before packed I/O")
            }
            if files.fileExists(at: f.common + "/refs/heads/main") {
                try files.deleteFile(at: f.common + "/refs/heads/main")
            }
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
                try assertOracle(f, label: "packed \(text.debugDescription)")
            }
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
            let table = try HeadRepository(base: base + "/table", shape: .folder, refFormat: "reftable")
            XCTAssertEqual(try table.git(["rev-parse", "--verify", "HEAD"]), table.oid)
            XCTAssertEqual(GitHeadStamp().state(root: table.root), .unreadable)
            for format in ["sha1", "sha256"] {
                let unsupported = try HeadRepository(base: base + "/extensions-" + format, shape: .folder, format: format)
                _ = try unsupported.git(["config", "core.repositoryformatversion", "1"])
                let configPath = unsupported.common + "/config"
                let config = try files.readFile(at: configPath)
                for header in ["[extensions]", "[extensions] # backend"] {
                    try files.writeFile(at: configPath,
                                        content: config + "\n" + header + "\nrefStorage = \"files\" # supported\n")
                    try assertOracle(unsupported, label: format + " quoted files backend")
                    for extensionLine in ["refStorage = reftable", "refStorage = future", "unknownExtension = true",
                                          "objectFormat = future", "refStorage = \"files#future\"",
                                          "objectFormat = \"sha1#future\""] {
                        try files.writeFile(at: configPath, content: config + "\n" + header + "\n" + extensionLine + "\n")
                        XCTAssertEqual(GitHeadStamp().state(root: unsupported.root), .unreadable, format + extensionLine)
                    }
                }
            }
        }
    }

    func assertOracle(_ fixture: HeadRepository, label: String,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let oracle = try TestPaths.git.run(["rev-parse", "--verify", "HEAD"], in: fixture.root)
        let symbolic = try TestPaths.git.run(["symbolic-ref", "-q", "HEAD"], in: fixture.root)
        let expected: GitHeadStamp.State
        if oracle.exit == 0 {
            expected = .resolved(oracle.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if symbolic.exit == 0 && oracle.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "fatal: Needed a single revision" {
            expected = .unborn
        } else {
            expected = .unreadable
        }
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

    init(base: String, shape: Shape, format: String = "sha1", refFormat: String = "files") throws {
        let files = FileService(), git = TestPaths.git
        root = base + "/store"
        try files.createDirectory(at: base)
        let initial = shape == .worktree ? base + "/primary" : root
        var arguments = ["init", "--initial-branch=main", "--object-format=" + format]
        if refFormat != "files" { arguments += ["--ref-format=" + refFormat] }
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
