import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension SyncBytePreservationTests {
    func testControlPreparationRefusesMetadataOnAnotherVolumeBeforeWriting() throws {
        try NativeTestWork.run { [self] in
            let probe = try StoreWriteCrashProbe(directory: base + "/cross-volume-probe")
            try probe.withVolume { volume in
                let root = base + "/cross-volume-store"
                _ = try TestPaths.git.runOrThrow(["init", "--separate-git-dir", volume + "/metadata", root], in: nil)
                let before = try files.listDirectory(at: volume + "/metadata").sorted()
                XCTAssertThrowsError(try TestPaths.git.prepareStoreRules(at: root, files: files)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("git's folder is on another volume"),
                                  error.localizedDescription)
                }
                XCTAssertEqual(try files.listDirectory(at: root), [".git"], "No control file is written before admission")
                XCTAssertEqual(try files.listDirectory(at: volume + "/metadata").sorted(), before)
                XCTAssertEqual(GitHeadStamp(fileService: files).state(root: root), .unreadable)
            }
        }
    }

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
                    try assertIntermediateOutsideWorktree(probe, root: fixture.root)
                    try assertCrashRecovery(fixture, label: source + ":" + point)
                    XCTAssertFalse(files.fileExists(at: try probe.intermediate()), "Sync must clean the killed control write")
                }
            }
            try assertControlCleanupIsBestEffort(probe: probe)
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
                    try assertIntermediateOutsideWorktree(probe, root: fixture.root)
                    try assertCrashRecovery(fixture, label: writer + ":" + point)
                    XCTAssertFalse(files.fileExists(at: try probe.intermediate()), "Sync must clean the killed skill write")
                }
            }
            try assertSkillWritesWithUnwritableParent(probe: probe)
            try assertSkillPublicationFailures(probe: probe)
            try assertVolumePublication(probe: probe)
        }
    }

    private func assertControlCleanupIsBestEffort(probe: StoreWriteCrashProbe) throws {
        let fixture = try crashStore(name: "cleanup")
        let leftover = fixture.root + "/.git/.pensieve-write-" + UUID().uuidString
        try files.writeFile(at: leftover, content: "abandoned")
        XCTAssertEqual(chflags(leftover, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(leftover, 0) }
        try files.writeFile(at: fixture.root + "/.gitattributes", content: "# regenerate\n")
        XCTAssertEqual(try probe.run(root: fixture.root, writer: "control", point: "complete"), 0,
                       "An unlinkable intermediate must not block control publication")
        XCTAssertNoThrow(try assertCrashRecovery(fixture, label: "unlinkable intermediate"))
        XCTAssertEqual(try files.readFile(at: leftover), "abandoned")
        try files.writeFile(at: fixture.root + "/.gitattributes", content: "# regenerate\n")
        XCTAssertEqual(try probe.run(root: fixture.root, writer: "control", point: "unsupported-lock"), 0,
                       "An unsupported cleanup lock must not block publication")
    }

    private func assertSkillPublicationFailures(probe: StoreWriteCrashProbe) throws {
        for metadata in ["absent", "malformed", "missing", "inside", "unwritable", "valid"] {
            let root = base + "/metadata-" + metadata
            let path = root + "/skills/existing/SKILL.md"
            try files.writeFile(at: path, content: "---\nname: Existing\ndescription: Fixture\n---\noriginal")
            try prepareSkillMetadata(metadata, root: root)
            for writer in ["create", "body", "rewrite"] {
                XCTAssertEqual(try probe.run(root: root, writer: writer, point: "unsupported-lock"), 0,
                               "Optional metadata or cleanup lock must not block \(writer): \(metadata)")
            }
            if metadata == "absent" {
                XCTAssertEqual(try probe.run(root: root, writer: "body", point: "namespace-race"), 0,
                               "A replaced namespace must not let another writer sweep a live intermediate")
            }
            XCTAssertEqual(chmod(path, 0o755), 0)
            for writer in ["body", "rewrite"] {
                XCTAssertEqual(try probe.run(root: root, writer: writer, point: "complete"), 0)
                var info = stat()
                XCTAssertEqual(lstat(path, &info), 0)
                XCTAssertEqual(info.st_mode & 0o777, 0o755, "A skill rewrite must preserve its executable mode")
            }
            try files.writeFile(at: path, content: "original before failed flush")
            let before = try files.readData(at: path)
            XCTAssertEqual(try probe.run(root: root, writer: "body", point: "failed-sync"), 1,
                           "A failed data flush must refuse publication")
            XCTAssertEqual(try files.readData(at: path), before)
        }
        try assertReplacedStoreAndLinkedNamespace(probe: probe)
    }

    private func prepareSkillMetadata(_ metadata: String, root: String) throws {
        switch metadata {
        case "malformed": try files.writeFile(at: root + "/.git", content: "not a gitdir")
        case "missing": try files.writeFile(at: root + "/.git", content: "gitdir: missing")
        case "inside":
            try files.createDirectory(at: root + "/nested")
            try files.writeFile(at: root + "/.git", content: "gitdir: nested")
        case "unwritable", "valid": try TestPaths.git.initRepository(at: root)
        default: break
        }
        if metadata == "unwritable" {
            XCTAssertEqual(chmod(root + "/.git", 0o555), 0)
            XCTAssertNotEqual(access(root + "/.git", W_OK), 0)
            addTeardownBlock { _ = chmod(root + "/.git", 0o755) }
        }
    }

    private func assertVolumePublication(probe: StoreWriteCrashProbe) throws {
        try probe.withVolume { volume in
            let skill = volume + "/skills/existing/SKILL.md"
            try files.writeFile(at: skill, content: "---\nname: Existing\ndescription: Fixture\n---\noriginal")
            XCTAssertEqual(try probe.run(root: volume, writer: "body", point: "complete"), 1)
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: volume + "/.TemporaryItems"),
                           "A refused volume-root save must not create a temporary tree inside the store")
            // Isolate the configured case even when a broken writer left the allocator's tree behind.
            if try files.entryExistsWithoutFollowingLinks(at: volume + "/.TemporaryItems") {
                try files.deleteDirectory(at: volume + "/.TemporaryItems")
            }
            try TestPaths.git.initRepository(at: volume)
            try files.writeFile(at: volume + "/.TemporaryItems", content: "user occupant")
            for writer in ["create", "body", "rewrite", "control"] {
                XCTAssertEqual(try probe.run(root: volume, writer: writer, point: "complete"), 0)
                XCTAssertFalse(files.fileExists(at: probe.library + ".locations"),
                               "Metadata publication must not allocate an unused fallback")
            }
            XCTAssertEqual(try files.readFile(at: volume + "/.TemporaryItems"), "user occupant")
            try files.deleteDirectory(at: volume + "/.git")
            try files.deleteFile(at: volume + "/.TemporaryItems")
            // The allocator's parent identity changes before admission; no intermediate may be written there.
            let nested = volume + "/nested"
            try files.writeFile(at: nested + "/skills/existing/SKILL.md", content: "original")
            for writer in ["create", "body", "rewrite"] {
                XCTAssertEqual(try probe.run(root: nested, writer: writer, point: "wrong-device"), 1)
                XCTAssertFalse(files.fileExists(at: probe.library + ".path"),
                               "Refuse a mismatched device before writing an intermediate")
            }
        }
    }

    private func assertReplacedStoreAndLinkedNamespace(probe: StoreWriteCrashProbe) throws {
        let root = base + "/replaced-store"
        try files.writeFile(at: root + "/skills/existing/SKILL.md", content: "original")
        XCTAssertEqual(try probe.run(root: root, writer: "body", point: "partial-write"), SIGKILL)
        let abandoned = try probe.intermediate()
        XCTAssertEqual(rename(root, root + "-old"), 0)
        XCTAssertEqual(try probe.run(root: root, writer: "create", point: "complete"), 0)
        XCTAssertFalse(files.fileExists(at: abandoned), "Replacing a store must not orphan its previous intermediate")
        let namespace = (try probe.intermediate() as NSString).deletingLastPathComponent
        let moved = namespace + ".saved"
        XCTAssertEqual(rename(namespace, moved), 0)
        defer { try? files.deleteDirectory(at: namespace); try? files.deleteDirectory(at: moved) }
        let outside = base + "/namespace-target"
        try files.createDirectory(at: outside)
        try files.createSymlink(at: namespace, pointingTo: outside)
        XCTAssertEqual(try probe.run(root: root, writer: "create", point: "complete"), 0,
                       "A linked cleanup namespace must not block a skill save")
        XCTAssertTrue(try files.listDirectory(at: outside).isEmpty)
        let spy = RetirementFileService()
        spy.cleanupFails = true
        let sync = SyncEngine(gitService: TestPaths.git, fileService: spy, lockPath: base + "/no-remote.lock")
        XCTAssertEqual(try sync.sync(root: root, message: "no remote", credential: nil, context: makeContext()), .noRemote,
                       "Cleanup failure must not turn an unconfigured sync into an error")
    }

    private func assertIntermediateOutsideWorktree(_ probe: StoreWriteCrashProbe, root: String) throws {
        let path = try probe.intermediate()
        let resolved = try files.resolveRealPath(at: root)
        XCTAssertTrue(!path.hasPrefix(resolved + "/") || path.hasPrefix(resolved + "/.git/"),
                      "A production intermediate must never be inside the worktree: \(path)")
    }

    private func assertSkillWritesWithUnwritableParent(probe: StoreWriteCrashProbe) throws {
        for initialized in [false, true] {
            let parent = base + "/readonly-" + String(initialized)
            let resolved = parent + "/store"
            let root = base + "/linked-" + String(initialized)
            try files.writeFile(at: resolved + "/skills/existing/SKILL.md",
                                content: "---\nname: Existing\ndescription: Existing skill\n---\noriginal")
            if initialized { try TestPaths.git.initRepository(at: resolved) }
            try files.createSymlink(at: root, pointingTo: resolved)
            XCTAssertEqual(chmod(parent, 0o555), 0)
            defer { _ = chmod(parent, 0o755) }
            XCTAssertNotEqual(access(parent, W_OK), 0, "Fixture parent must actually refuse writes")
            for writer in ["create", "body", "rewrite"] {
                XCTAssertEqual(try probe.run(root: root, writer: writer, point: "complete"), 0,
                               "\(writer) must save with an unwritable resolved parent, git=\(initialized)")
            }
            XCTAssertTrue(try files.readFile(at: root + "/skills/existing/SKILL.md").contains("rewritten body"))
            XCTAssertTrue(files.fileExists(at: root + "/skills/new/SKILL.md"))
            // The next real writer must also reclaim an intermediate left by a killed predecessor.
            XCTAssertEqual(try probe.run(root: root, writer: "body", point: "partial-write"), SIGKILL)
            let abandoned = try probe.intermediate()
            let unrelated = base + "/unrelated-" + String(initialized)
            XCTAssertEqual(try probe.run(root: unrelated, writer: "create", point: "complete"), 0)
            XCTAssertTrue(files.fileExists(at: abandoned), "Another store must not consume this store's abandoned write")
            XCTAssertEqual(try probe.run(root: root, writer: "body", point: "complete"), 0)
            XCTAssertFalse(files.fileExists(at: abandoned), "The next skill save must clean the abandoned write")
            if !initialized {
                XCTAssertEqual(try probe.run(root: root, writer: "body", point: "partial-write"), SIGKILL)
                let beforeSetup = try probe.intermediate()
                let sync = SyncEngine(gitService: TestPaths.git, fileService: files, lockPath: base + "/unconfigured.lock")
                XCTAssertEqual(try sync.sync(root: root, message: "unconfigured", credential: nil,
                                             context: makeContext()), .noRemote)
                XCTAssertFalse(files.fileExists(at: beforeSetup), "An unconfigured sync must also reclaim its killed write")
            }
        }
    }

    func testOlderIgnoreTemporaryNeverReachesPushedCommit() throws {
        try NativeTestWork.run { [self] in
            let fixture = try crashStore(name: "legacy")
            let name = ".pensieve-ignore-" + UUID().uuidString
            try files.writeFile(at: fixture.root + "/" + name, content: "old writer intermediate")
            let nested = "skills/existing/.pensieve-ignore-notes"
            try files.writeFile(at: fixture.root + "/" + nested, content: "skill notes")
            try assertCrashRecovery(fixture, label: name)
            XCTAssertEqual(try fixture.git.show(sha: "HEAD", path: nested, at: fixture.root), "skill notes",
                           "Only root legacy intermediates are excluded")
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
                guard source != ".gitignore" else {
                    XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("link"),
                                  "The root-ignore refusal must identify the link")
                    return
                }
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
            try assertOperationCacheBoundaries()
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
            spy.cleanupCalls = 0
            _ = try engine.sync(root: root, message: "unchanged", credential: nil, context: context)
            XCTAssertEqual(spy.cleanupCalls, 1, "A sync must request only one operation-wide intermediate cleanup")
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
        XCTAssertFalse(paths.split(separator: "\n").contains { $0.hasPrefix(".pensieve-ignore-") }, label)
        XCTAssertTrue(fixture.git.isWorktreeClean(at: fixture.root), label)
    }
}
