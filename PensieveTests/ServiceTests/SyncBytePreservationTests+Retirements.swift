import Darwin
import XCTest
@testable import Pensieve

extension SyncBytePreservationTests {
    func testUnreadableRetirementSourcesStopBeforeWrites() throws {
        try files.writeFile(at: base + "/outside", content: "outside bytes")
        for source in [".gitattributes", ".pensieve-retired-paths"] {
            for kind in ["oversized", "utf8", "symlink", "eio"] {
                let store = base + "/" + source + "-" + kind
                try files.createDirectory(at: store)
                try TestPaths.git.initRepository(at: store)
                let path = store + "/" + source
                switch kind {
                case "oversized": try files.writeData(at: path, data: Data(repeating: 65, count: 1_048_577))
                case "utf8": try files.writeData(at: path, data: Data([255]))
                case "symlink":
                    try files.writeFile(at: base + "/outside", content: "outside bytes")
                    try files.createSymlink(at: path, pointingTo: base + "/outside")
                default: try files.writeFile(at: path, content: "receipt source")
                }
                let spy = RetirementFileService()
                spy.readFailure = kind == "eio" ? path : nil
                XCTAssertThrowsError(try StoreIgnoreRules.prepare(at: store, files: spy), "R2: \(source), \(kind)")
                XCTAssertTrue(spy.writes.isEmpty, "An unreadable source must precede any write")
                let git = GitService(fileService: spy, askpassHelperPath: base + "/askpass")
                XCTAssertThrowsError(try git.storeOperation(at: store), "Receipt refusal also precedes metadata writes")
                XCTAssertTrue(spy.writes.isEmpty)
                XCTAssertEqual(try files.readFile(at: base + "/outside"), "outside bytes")
            }
        }
        let missing = base + "/missing"
        try files.createDirectory(at: missing)
        XCTAssertNoThrow(try StoreIgnoreRules.prepare(at: missing, files: files), "Absence means no receipts")
    }

    func testRetirementReceiptsCannotHideSyncedStructure() throws {
        for path in ["skills", "manifest", "skills/x", "skills/x/SKILL.md", "skills/x/skill.md", "skills/x/ſkill.md",
                     ".gitignore",
                     "manifest/skills/x.yaml", "skills/../manifest", "skills/x/assets/../SKILL.md"] {
            let store = base + "/invalid-" + UUID().uuidString
            try files.createDirectory(at: store)
            let receipt = "# Pensieve retired path: " + Data(path.utf8).base64EncodedString() + "\n"
            try files.writeFile(at: store + "/.gitattributes", content: receipt)
            let spy = RetirementFileService()
            XCTAssertThrowsError(try StoreIgnoreRules.prepare(at: store, files: spy), "R3: refused path \(path)")
            XCTAssertTrue(spy.writes.isEmpty)
        }
        let store = base + "/valid"
        try files.createDirectory(at: store)
        try TestPaths.git.initRepository(at: store)
        try StoreIgnoreRules.prepare(at: store, files: files, retiring: "skills/x/assets/legacy")
        try files.writeFile(at: store + "/skills/x/assets/legacy/keep", content: "retired bytes")
        try files.writeFile(at: store + "/skills/new/SKILL.md", content: "new skill")
        try TestPaths.git.stageAllAndCommit(at: store, message: "safe receipt")
        let tree = try TestPaths.git.runOrThrow(["-C", store, "ls-tree", "-r", "--name-only", "HEAD"], in: nil).stdout
        XCTAssertTrue(tree.contains("skills/new/SKILL.md"))
        XCTAssertFalse(tree.contains("skills/x/assets/legacy/keep"))
    }

    func testRuleTemporaryWritesCannotBeStagedAtWriteBoundary() throws {
        let store = base + "/crash-store"
        try files.createDirectory(at: store)
        try TestPaths.git.initRepository(at: store)
        try files.writeFile(at: store + "/.gitignore", content: "previous rules")
        let spy = RetirementFileService()
        spy.afterWrite = { path in
            if path.contains(".pensieve-") && !path.contains("/.git/") {
                try TestPaths.git.stageAllAndCommit(at: store, message: "crash snapshot")
                let tracked = try TestPaths.git.runOrThrow(["-C", store, "ls-files"], in: nil).stdout
                XCTAssertFalse(tracked.contains(".pensieve-ignore-"), "R6: a kill here must not publish the temporary file")
            }
        }
        try StoreIgnoreRules.prepare(at: store, files: spy)
        XCTAssertTrue(spy.writes.filter { $0.contains(".pensieve-ignore-") }.allSatisfy {
            !PathSyntax.isWithin($0, root: store)
        }, "Temporary rules belong outside the worktree")
    }
}

/// Faults only receipt reads and observes completed writes; other modeled I/O forwards to a temp store.
/// It does not intercept Git's own metadata writes or pretend to simulate process termination.
private final class RetirementFileService: FileServiceProtocol {
    let wrapped = FileService()
    var readFailure: String?
    var writes: [String] = []
    var afterWrite: ((String) throws -> Void)?
    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func readRegularFileData(at path: String, maximumBytes: Int, containedIn directory: String) throws -> Data {
        if path == readFailure { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        return try wrapped.readRegularFileData(at: path, maximumBytes: maximumBytes, containedIn: directory)
    }
    func writeFile(at path: String, content: String) throws {
        writes.append(path)
        try wrapped.writeFile(at: path, content: content)
        try afterWrite?(path)
    }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        try wrapped.entryTypeWithoutFollowingLinks(at: path)
    }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}
