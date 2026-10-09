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
                XCTAssertThrowsError(try StoreIgnoreRules.prepare(at: store, files: spy), "R2: \(source), \(kind)") {
                    XCTAssertEqual($0.localizedDescription,
                        "Pensieve can't read its list of retired paths (\(source)), so sync stopped. "
                        + "Restore that file from another Mac, then sync again.")
                }
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

    func testMalformedReceiptsRefuseWritesWhileRetiredChildrenStayUnstaged() throws {
        for source in [".gitattributes", ".pensieve-retired-paths"] {
            for path in ["", "skills//x", "skills/./x", "skills/../manifest", "skills/x/assets/../SKILL.md",
                         "skills/x/", "skills/x/\u{0001}child"] {
                let store = base + "/invalid-" + UUID().uuidString
                try files.createDirectory(at: store)
                let receipt = "# Pensieve retired path: " + Data(path.utf8).base64EncodedString() + "\n"
                try files.writeFile(at: store + "/" + source, content: receipt)
                let spy = RetirementFileService()
                XCTAssertThrowsError(try StoreIgnoreRules.prepare(at: store, files: spy), path) { error in
                    XCTAssertEqual(error.localizedDescription,
                        "Pensieve's list of retired paths (\(source)) names a path it can't use: \(path). "
                        + "Remove that line, then sync again.")
                }
                XCTAssertTrue(spy.writes.isEmpty, "Invalid receipts must precede writes")
                XCTAssertEqual(try files.readFile(at: store + "/" + source), receipt)
            }
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
        XCTAssertEqual(try files.readFile(at: store + "/skills/x/assets/legacy/keep"), "retired bytes")
    }

    func testControlFileFoldersSurvivePreparation() throws {
        for source in [".gitattributes", ".pensieve-retired-paths", ".gitignore"] {
            for arrivesAfterRead in [false, true] {
                // Root ignore input is not read; its folder needs just one shape.
                if source == ".gitignore" && arrivesAfterRead { continue }
                let store = base + "/control-folder-" + UUID().uuidString
                try files.createDirectory(at: store)
                let path = store + "/" + source
                let receiptPath = store + "/.pensieve-retired-paths"
                let original = "# Pensieve retired path: " + Data("skills/x/assets/old".utf8).base64EncodedString() + "\n"
                if source != ".pensieve-retired-paths" { try files.writeFile(at: receiptPath, content: original) }
                let spy = RetirementFileService()
                if arrivesAfterRead {
                    try files.writeFile(at: path, content: "")
                    spy.afterRead = { readPath in
                        guard readPath == path else { return }
                        try self.files.deleteFile(at: path)
                        try self.files.writeFile(at: path + "/keep", content: "user folder bytes")
                    }
                } else {
                    try files.writeFile(at: path + "/keep", content: "user folder bytes")
                }
                if source == ".gitignore" {
                    XCTAssertNoThrow(try StoreIgnoreRules.prepare(at: store, files: spy,
                        retiring: "skills/x/assets/legacy"))
                    XCTAssertEqual(try StoreIgnoreRules.retiredPaths(at: store, files: files),
                                   ["skills/x/assets/legacy", "skills/x/assets/old"])
                } else {
                    XCTAssertThrowsError(try StoreIgnoreRules.prepare(at: store, files: spy,
                        retiring: "skills/x/assets/legacy"), "\(source), after read: \(arrivesAfterRead)")
                    if source == ".gitattributes" {
                        XCTAssertEqual(try files.readFile(at: receiptPath), original,
                                       "A failed attributes write must not publish an uncompleted retirement")
                    }
                }
                XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: path), .directory)
                XCTAssertEqual(try files.readFile(at: path + "/keep"), "user folder bytes")
            }
        }
    }
}

/// Faults receipt reads, permits a real entry replacement after a read, and observes writes.
/// Other modeled I/O forwards to a temp store; replacement never supplies a mocked read result.
/// It does not intercept Git's own metadata writes or pretend to simulate process termination.
private final class RetirementFileService: FileServiceProtocol {
    let wrapped = FileService()
    var readFailure: String?
    var writes: [String] = []
    var afterRead: ((String) throws -> Void)?
    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func readRegularFileData(at path: String, maximumBytes: Int, containedIn directory: String) throws -> Data {
        if path == readFailure { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        let data = try wrapped.readRegularFileData(at: path, maximumBytes: maximumBytes, containedIn: directory)
        try afterRead?(path)
        return data
    }
    func writeFile(at path: String, content: String) throws {
        writes.append(path)
        try wrapped.writeFile(at: path, content: content)
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
