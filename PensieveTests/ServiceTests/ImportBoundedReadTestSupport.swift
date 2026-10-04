import Darwin
import XCTest
@testable import Pensieve

/// Forwards filesystem operations to a temporary tree and records both text reads and actual
/// descriptor read counts. Growth happens on the first read callback, after production fstat.
/// A device entry forwards descriptor admission to /dev/null because unprivileged tests cannot
/// create device nodes. Its text-read sentinel exposes an unsafe scanner. Other fixtures are real
/// files, links, directories and FIFOs.
/// Tree comparisons forward to the same filesystem and record the caller's main-thread status.
/// An optional comparison failure injects a path-bearing error after checkout admission.
final class ImportBoundedReadSpy: FileServiceProtocol {
    let files = FileService()
    var devicePath: String?
    var unreadablePath: String?
    var growPath: String?
    var growthSize = 0
    var textReads: [String] = []
    var limits: [String: Int] = [:]
    var consumed: [String: Int] = [:]
    var requests: [String: [Int]] = [:]
    var readAttempts: [String] = []
    var regularProbes: [String] = []
    var presenceProbes: [String] = []
    var directoryProbes: [String] = []
    var readFailures: [String: Int32] = [:]
    var comparisonThreads: [Bool] = []
    var comparisonFailure: ((String, String) throws -> Void)?

    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        try files.entryTypeWithoutFollowingLinks(at: path)
    }

    func compareFileTrees(local: String, upstream: String, excludingUpstreamGit: Bool,
                          limits: FileTreeComparisonLimits) throws -> FileTreeComparison {
        comparisonThreads.append(Thread.isMainThread)
        try comparisonFailure?(local, upstream)
        return try files.compareFileTrees(local: local, upstream: upstream, excludingUpstreamGit: excludingUpstreamGit,
                                          limits: limits)
    }

    func readFile(at path: String) throws -> String {
        textReads.append(path)
        if path == devicePath { return "device sentinel" }
        return try files.readFile(at: path)
    }

    func readRegularFilePrefix(at path: String, maximumBytes: Int) throws -> Data {
        readAttempts.append(path)
        limits[path] = maximumBytes
        return try files.readRegularFilePrefix(at: path, maximumBytes: maximumBytes)
    }

    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        readAttempts.append(path)
        limits[path] = maximumBytes
        if let code = readFailures[path] { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        if path == unreadablePath { throw CocoaError(.fileReadNoPermission) }
        return try files.readRegularFileData(at: path == devicePath ? "/dev/null" : path,
                                             maximumBytes: maximumBytes) { descriptor, buffer, count in
            if path == self.growPath {
                self.growPath = nil
                // Fixture-only POSIX mutation preserves the inode held by the reader.
                let writer = open(path, O_WRONLY)
                XCTAssertGreaterThanOrEqual(writer, 0)
                if writer >= 0 {
                    XCTAssertEqual(ftruncate(writer, off_t(self.growthSize)), 0)
                    close(writer)
                }
            }
            self.requests[path, default: []].append(count)
            let result = Darwin.read(descriptor, buffer, count)
            if result > 0 { self.consumed[path, default: 0] += result }
            return result
        }
    }

    func isRegularFile(at path: String) -> Bool {
        regularProbes.append(path)
        return files.isRegularFile(at: path == devicePath ? "/dev/null" : path)
    }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        presenceProbes.append(path)
        if path == devicePath { return true }
        return try files.entryExistsWithoutFollowingLinks(at: path)
    }
    func listDirectory(at path: String) throws -> [String] {
        var entries = try files.listDirectory(at: path)
        if let devicePath, (devicePath as NSString).deletingLastPathComponent == path {
            entries.append((devicePath as NSString).lastPathComponent)
        }
        return entries
    }
    func writeFile(at path: String, content: String) throws { try files.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try files.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { files.fileExists(at: path) }
    func realPath(at path: String) -> String { files.realPath(at: path) }
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        files.fileIdentity(at: path, followingLinks: followingLinks)
    }
    func isExecutableFile(at path: String) -> Bool { files.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool {
        directoryProbes.append(path)
        return files.directoryExists(at: path)
    }
    func createDirectory(at path: String) throws { try files.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try files.deleteDirectory(at: path) }
    func createSymlink(at path: String, pointingTo target: String) throws {
        try files.createSymlink(at: path, pointingTo: target)
    }
    func symlinkTarget(at path: String) throws -> String { try files.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { files.isSymlink(at: path) }
    func contentsHash(at path: String) throws -> String { try files.contentsHash(at: path) }
}
