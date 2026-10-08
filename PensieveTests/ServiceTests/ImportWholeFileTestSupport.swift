import Darwin
import XCTest
@testable import Pensieve

/// Runs fixture scans off the test thread with the shared positive-wait deadline. Holding a FIFO writer
/// lets a blocking reader open, but keeps it waiting for EOF. On timeout, closing that writer
/// releases the read and fails the test. This bounds the fixture's open/read failures, not
/// arbitrary deadlocks. All ordinary file I/O still goes through the injected FileService.
func boundedImportScan(fifo: String, scan: @escaping () -> [DiscoveredSkill]) throws -> [DiscoveredSkill] {
    let writer = open(fifo, O_RDWR | O_NONBLOCK)
    guard writer >= 0 else { throw CocoaError(.fileReadUnknown) }
    let result = ImportScanResult()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        result.skills = scan()
        done.signal()
    }
    let finished = done.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds) == .success
    close(writer)
    guard finished else {
        // Release a blocked fixture reader before teardown, without an unbounded join.
        _ = done.wait(timeout: .now() + 2) // upper-bound: Bound cleanup after releasing a blocked FIFO reader.
        XCTFail("Import scan blocked on the FIFO beyond the shared wait bound")
        throw CocoaError(.fileReadUnknown)
    }
    return result.skills
}

/// The worker writes before signalling; the caller reads only after the semaphore succeeds.
private final class ImportScanResult {
    var skills: [DiscoveredSkill] = []
}

/// Records bytes only after the real text or descriptor reader returns successfully. Refused
/// opens do not count as reads. Unsafe text reads remain observable through sentinel contents;
/// boundedImportScan releases the fixture FIFO if a reader blocks. Other methods only forward.
final class ImportReadSpy: FileServiceProtocol {
    let files: FileService
    var returnedBytes: [Data] = []
    var writtenPaths: [String] = []
    init(files: FileService) { self.files = files }
    func readFile(at path: String) throws -> String {
        let content = try files.readFile(at: path)
        returnedBytes.append(Data(content.utf8))
        return content
    }
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        let data = try files.readRegularFileData(at: path, maximumBytes: maximumBytes)
        returnedBytes.append(data)
        return data
    }
    func copyImportedSkillContents(fromDirectory source: String,
                                   toDirectory destination: String) throws -> [SkillFolderCopySkip] {
        try files.copyImportedSkillContents(fromDirectory: source, toDirectory: destination)
    }
    func writeFile(at path: String, content: String) throws {
        writtenPaths.append(path)
        try files.writeFile(at: path, content: content)
    }
    func deleteFile(at path: String) throws { try files.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { files.fileExists(at: path) }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        try files.entryExistsWithoutFollowingLinks(at: path)
    }
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        try files.entryTypeWithoutFollowingLinks(at: path)
    }
    func realPath(at path: String) -> String { files.realPath(at: path) }
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        files.fileIdentity(at: path, followingLinks: followingLinks)
    }
    func isExecutableFile(at path: String) -> Bool { files.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { files.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try files.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try files.deleteDirectory(at: path) }
    func createSymlink(at path: String, pointingTo target: String) throws {
        try files.createSymlink(at: path, pointingTo: target)
    }
    func symlinkTarget(at path: String) throws -> String { try files.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { files.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool { files.isRegularFile(at: path) }
    func listDirectory(at path: String) throws -> [String] { try files.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try files.contentsHash(at: path) }
}
