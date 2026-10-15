import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension SyncBytePreservationTests {
    func testControlWriterCrashPointsNeverStageIntermediates() throws {
        try NativeTestWork.run { [self] in
            let probe = try StoreWriteCrashProbe(directory: base + "/probe")
            for source in [".gitignore", ".gitattributes", StoreIgnoreRules.receiptFile] {
                for point in ["before-write", "partial-write", "after-write", "before-rename", "after-rename"] {
                    let fixture = try crashStore(name: UUID().uuidString)
                    let path = fixture.root + "/" + source
                    let input = source == StoreIgnoreRules.receiptFile
                        ? "# Pensieve retired path: " + Data("skills/existing/old".utf8).base64EncodedString() + "\r\n"
                        : "# noncanonical but valid input\n"
                    try files.writeFile(at: path, content: input)
                    XCTAssertEqual(try probe.run(root: fixture.root, writer: "control", point: point), SIGKILL,
                                   "The real \(source) writer must reach \(point)")
                    try assertCrashRecovery(fixture, label: source + ":" + point)
                }
            }
        }
    }

    func testSkillWriterCrashPointsNeverStageIntermediates() throws {
        try NativeTestWork.run { [self] in
            let probe = try StoreWriteCrashProbe(directory: base + "/probe")
            for writer in ["create", "body", "rewrite"] {
                for point in ["before-write", "partial-write", "after-write", "before-rename", "after-rename"] {
                    let fixture = try crashStore(name: UUID().uuidString)
                    XCTAssertEqual(try probe.run(root: fixture.root, writer: writer, point: point), SIGKILL,
                                   "The real \(writer) writer must reach \(point)")
                    try assertCrashRecovery(fixture, label: writer + ":" + point)
                }
            }
        }
    }

    func testOlderIgnoreTemporaryNeverReachesPushedCommit() throws {
        try NativeTestWork.run { [self] in
            let fixture = try crashStore(name: "legacy")
            let name = ".pensieve-ignore-" + UUID().uuidString
            try files.writeFile(at: fixture.root + "/" + name, content: "old writer intermediate")
            try assertCrashRecovery(fixture, label: name)
            XCTAssertEqual(try files.readFile(at: fixture.root + "/" + name), "old writer intermediate")
        }
    }

    func testControlPublicationRefusesRacedFoldersAndCheckedLinks() throws {
        try NativeTestWork.run { [self] in
            let probe = try StoreWriteCrashProbe(directory: base + "/probe")
            for source in [".gitignore", ".gitattributes", StoreIgnoreRules.receiptFile] {
                for point in ["link-before-check", "folder-before-check", "folder-after-check"] {
                    let fixture = try crashStore(name: UUID().uuidString)
                    try files.writeFile(at: base + "/outside", content: "target")
                    let path = fixture.root + "/" + source
                    let input = source == StoreIgnoreRules.receiptFile
                        ? "# Pensieve retired path: " + Data("skills/existing/old".utf8).base64EncodedString() + "\r\n"
                        : "# regenerate\n"
                    try files.writeFile(at: path, content: input)
                    let status = try probe.run(root: fixture.root, writer: "control", point: point, destination: path)
                    XCTAssertEqual(status, source == ".gitignore" && point != "link-before-check" ? 0 : 1)
                    if point == "link-before-check" {
                        XCTAssertEqual(try files.symlinkTarget(at: path), "../outside")
                    } else {
                        XCTAssertEqual(try files.readFile(at: path + "/keep"), "keep")
                    }
                    XCTAssertEqual(try files.readFile(at: base + "/outside"), "target")
                }
            }
        }
    }

    func testSyncPreservesControlOccupantsBeforeAndDuringPreparation() throws {
        try NativeTestWork.run { [self] in
            for source in [".gitignore", ".gitattributes", StoreIgnoreRules.receiptFile] {
                for link in [false, true] {
                    for during in [false, true] {
                        try assertSyncControlOccupant(source: source, link: link, during: during)
                    }
                }
            }
        }
    }

    private func assertSyncControlOccupant(source: String, link: Bool, during: Bool) throws {
        let name = UUID().uuidString
        let fixture = try crashStore(name: name)
        let path = fixture.root + "/" + source
        let outside = base + "/outside"
        try files.writeFile(at: outside, content: "target")
        try files.writeFile(at: path, content: "# regenerate\n")
        let occupy = {
            try self.files.deleteFile(at: path)
            if link { try self.files.createSymlink(at: path, pointingTo: outside) } else {
                try self.files.writeFile(at: path + "/keep", content: "keep")
            }
        }
        let spy = RetirementFileService()
        var arrivals = 0
        if during {
            spy.afterRead = { readPath in
                guard readPath == path, arrivals == 0 else { return }
                arrivals += 1
                try occupy()
            }
        } else { try occupy() }
        let git = GitService(fileService: spy, askpassHelperPath: base + "/askpass",
                             executablePath: base + "/" + name + "-user/git")
        let engine = SyncEngine(gitService: git, fileService: spy, lockPath: base + "/sync.lock")
        if source == ".gitignore" && !link {
            XCTAssertNoThrow(try engine.sync(root: fixture.root, message: "folder", credential: nil, context: fixture.context))
        } else {
            XCTAssertThrowsError(try engine.sync(root: fixture.root, message: "refuse", credential: nil,
                                                 context: fixture.context)) { error in
                guard source != ".gitignore" else { return }
                let read = Result { try self.files.readRegularFileData(at: path, maximumBytes: 1_048_576) }
                if case let .failure(original) = read {
                    XCTAssertEqual(error.localizedDescription, original.localizedDescription)
                } else { XCTFail("The preserved control entry must still refuse a regular-file read") }
            }
        }
        XCTAssertEqual(arrivals, during ? 1 : 0)
        if link { XCTAssertEqual(try files.symlinkTarget(at: path), outside) } else {
            XCTAssertEqual(try files.readFile(at: path + "/keep"), "keep")
        }
        XCTAssertEqual(try files.readFile(at: outside), "target")
    }

    func testUnchangedSyncDoesNotRepublishControlOrMetadataRules() throws {
        try NativeTestWork.run { [self] in
            let remote = base + "/stable.git"
            let spy = RetirementFileService()
            let git = try userGit("stable", remote: remote, skillRules: true, fileService: spy)
            try seedRemote(git: git, remote: remote)
            let root = base + "/store"
            try git.clone(remote: remoteURL, into: root, credential: nil)
            let engine = SyncEngine(gitService: git, fileService: spy, lockPath: base + "/sync.lock")
            let context = try makeContext()
            try files.writeFile(at: root + "/.pensieve-retired-paths", content: "")
            _ = try engine.sync(root: root, message: "prepare", credential: nil, context: context)
            spy.writes.removeAll()
            _ = try engine.sync(root: root, message: "unchanged", credential: nil, context: context)
            for path in [".gitignore", ".gitattributes", ".pensieve-retired-paths", ".git/info/pensieve-ignore"] {
                XCTAssertFalse(spy.writes.contains(root + "/" + path), path)
            }
            // Scope ends with the operation: a later external receipt must affect the next sync.
            let path = "skills/existing/retired"
            try files.writeFile(at: root + "/.pensieve-retired-paths",
                content: "# Pensieve retired path: " + Data(path.utf8).base64EncodedString() + "\n")
            try files.writeFile(at: root + "/" + path, content: "local")
            _ = try engine.sync(root: root, message: "new receipt", credential: nil, context: context)
            let tree = try git.runOrThrow(["--git-dir", remote, "ls-tree", "-r", "--name-only", "main"], in: nil).stdout
            XCTAssertFalse(tree.contains(path))
        }
    }

    private struct CrashStore {
        let root: String
        let remote: String
        let git: GitService
        let context: ModelContext
    }

    private func crashStore(name: String) throws -> CrashStore {
        let remote = base + "/" + name + ".git"
        let git = try userGit(name + "-user", remote: remote, skillRules: true)
        // seedRemote's seed name is shared, so reuse its remote seed only for this fixture.
        let seed = base + "/seed"
        if files.directoryExists(at: seed) { try files.deleteDirectory(at: seed) }
        try seedRemote(git: git, remote: remote)
        let root = base + "/" + name
        try git.clone(remote: remoteURL, into: root, credential: nil)
        let context = try makeContext()
        let store = SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
        _ = try store.createSkill(name: "existing", description: "Existing skill", body: "original")
        _ = StoreRebuildService().rebuild(fromRoot: root, context: context)
        try files.writeFile(at: root + "/" + StoreIgnoreRules.receiptFile, content: "")
        _ = try engine(git: git).sync(root: root, message: "baseline", credential: nil, context: context)
        return CrashStore(root: root, remote: remote, git: git, context: context)
    }

    private func assertCrashRecovery(_ fixture: CrashStore, label: String) throws {
        _ = StoreRebuildService().rebuild(fromRoot: fixture.root, context: fixture.context)
        _ = try engine(git: fixture.git).sync(root: fixture.root, message: "recover", credential: nil,
                                             context: fixture.context)
        let paths = try fixture.git.runOrThrow(["--git-dir", fixture.remote, "ls-tree", "-r", "--name-only", "main"],
                                               in: nil).stdout
        XCTAssertFalse(paths.contains(".pensieve-write-"), label)
        XCTAssertFalse(paths.contains(".pensieve-ignore-"), label)
        XCTAssertTrue(fixture.git.isWorktreeClean(at: fixture.root), label)
    }
}
