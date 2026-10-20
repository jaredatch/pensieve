import Foundation
@testable import Pensieve

/// Holds sampled SKILL.md reads at the real filesystem boundary. Main-thread reads are recorded
/// without blocking, so the owner can diagnose an actor regression without wedging its test host.
/// Optional manifest-build and skill-listing refusals exercise publication and scan failures.
/// Other I/O delegates to FileService; the double supplies no rebuild or merge result.
final class RebuildReadFileService: FileServiceProtocol, FileEntryObserving {
    private var containedReads: [String] = []
    var containedRegularReadPaths: [String] { lock.withLock { containedReads } }
    let entryObservations = Counter()
    let headReads = Counter()
    let skillListings = Counter()
    let separateTypeReads = Counter()
    func entryObservation(at path: String) throws -> FileEntryObservation {
        entryObservations.increment()
        return try wrapped.entryObservation(at: path)
    }
    var afterRead: ((String) throws -> Void)?
    var refuseReplacement = false
    var refuseSkillListing = false
    private var refusedListings = 0
    var skillListingRefusals: Int { lock.withLock { refusedListings } }
    private let wrapped = FileService()
    private let lock = NSLock()
    private var gates: [TestWait.Gate] = []
    private var mainReads = 0

    var mainThreadReads: Int { lock.withLock { mainReads } }
    func hold(_ gates: [TestWait.Gate]) { lock.withLock { self.gates = gates } }

    func readFile(at path: String) throws -> String {
        if path.hasSuffix("/HEAD") { headReads.increment() }
        let value = try wrapped.readFile(at: path)
        try afterRead?(path)
        guard path.hasSuffix("/alpha/SKILL.md") else { return value }
        let gate: TestWait.Gate? = lock.withLock {
            if Thread.isMainThread { mainReads += 1; return nil }
            return gates.isEmpty ? nil : gates.removeFirst()
        }
        try gate?.wait()
        return value
    }

    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func readData(at path: String) throws -> Data { try wrapped.readData(at: path) }
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        return try wrapped.readRegularFileData(at: path, maximumBytes: maximumBytes)
    }
    func readRegularFileHeader(at path: String, maximumBytes: Int) throws -> Data {
        try wrapped.readRegularFileHeader(at: path, maximumBytes: maximumBytes)
    }
    func readRegularFileData(at path: String, maximumBytes: Int, containedIn directory: String) throws -> Data {
        lock.withLock { containedReads.append(path) }
        return try wrapped.readRegularFileData(at: path, maximumBytes: maximumBytes, containedIn: directory)
    }
    func writeFile(at path: String, content: String) throws {
        if refuseReplacement && path.contains(".manifest-build-") { throw CocoaError(.fileWriteNoPermission) }
        try wrapped.writeFile(at: path, content: content)
    }
    func writeData(at path: String, data: Data) throws { try wrapped.writeData(at: path, data: data) }
    func writeExecutableFile(at path: String, content: String) throws {
        try wrapped.writeExecutableFile(at: path, content: content)
    }
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        try wrapped.copyFile(at: sourcePath, to: destinationPath)
    }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        try wrapped.entryExistsWithoutFollowingLinks(at: path)
    }
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        separateTypeReads.increment()
        return try wrapped.entryTypeWithoutFollowingLinks(at: path)
    }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func isUserExecutableFile(at path: String) -> Bool { wrapped.isUserExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func directoryExistsFollowingLinks(at path: String) throws -> Bool { try wrapped.directoryExistsFollowingLinks(at: path) }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func createDirectoryWithoutParents(at path: String) throws { try wrapped.createDirectoryWithoutParents(at: path) }
    func writeFileWithoutParents(at path: String, content: String) throws {
        try wrapped.writeFileWithoutParents(at: path, content: content)
    }
    func createSymlinkWithoutParents(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlinkWithoutParents(at: linkPath, pointingTo: targetPath)
    }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isRegularFile(at path: String) -> Bool { wrapped.isRegularFile(at: path) }
    func listDirectory(at path: String) throws -> [String] {
        if path.hasSuffix("/skills") { skillListings.increment() }
        if refuseSkillListing, path.hasSuffix("/skills") {
            lock.withLock { refusedListings += 1 }
            throw CocoaError(.fileReadNoPermission)
        }
        return try wrapped.listDirectory(at: path)
    }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        wrapped.fileIdentity(at: path, followingLinks: followingLinks)
    }
    func realPath(at path: String) -> String { wrapped.realPath(at: path) }
    func resolveRealPath(at path: String) throws -> String { try wrapped.resolveRealPath(at: path) }
    func regularFileMetadata(at path: String) -> RegularFileMetadata? { wrapped.regularFileMetadata(at: path) }
    func touchRegularFile(at path: String, date: Date) throws { try wrapped.touchRegularFile(at: path, date: date) }

    func storeTemporaryParent(root: String) throws -> String { try wrapped.storeTemporaryParent(root: root) }
}
