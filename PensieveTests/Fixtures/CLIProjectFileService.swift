import Foundation
import XCTest
@testable import Pensieve

/// Delegates to real fixture files and records the thread for canonicalization, project admission
/// and marker writes. Optional hooks pause admission, completed marker reads or marker writes
/// to order competing real operations; they supply neither identity nor registration results.
final class CLIProjectFileService: FileServiceProtocol {
    private let wrapped = FileService()
    private let lock = NSLock()
    var beforeProjectProbe: (() throws -> Void)?
    var afterMarkerRead: (() throws -> Void)?
    var beforeMarkerWrite: (() throws -> Void)?
    private var markerWrites = 0
    var markerWriteCount: Int { lock.withLock { markerWrites } }
    private var probes = 0
    private var mainProbes = 0
    var probeCounts: (total: Int, main: Int) { lock.withLock { (probes, mainProbes) } }
    private func noteProbe() { lock.withLock { probes += 1; if Thread.isMainThread { mainProbes += 1 } } }
    func readFile(at path: String) throws -> String {
        let result = Result { try wrapped.readFile(at: path) }
        if (path as NSString).lastPathComponent == ".pensieve-project" { try afterMarkerRead?() }
        return try result.get()
    }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func readData(at path: String) throws -> Data { try wrapped.readData(at: path) }
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        try wrapped.readRegularFileData(at: path, maximumBytes: maximumBytes)
    }
    func readRegularFileHeader(at path: String, maximumBytes: Int) throws -> Data {
        try wrapped.readRegularFileHeader(at: path, maximumBytes: maximumBytes)
    }
    func readRegularFileData(at path: String, maximumBytes: Int, containedIn directory: String) throws -> Data {
        try wrapped.readRegularFileData(at: path, maximumBytes: maximumBytes, containedIn: directory)
    }
    func writeFile(at path: String, content: String) throws {
        noteProbe(); try wrapped.writeFile(at: path, content: content)
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
        try wrapped.entryTypeWithoutFollowingLinks(at: path)
    }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func isUserExecutableFile(at path: String) -> Bool { wrapped.isUserExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func directoryExistsFollowingLinks(at path: String) throws -> Bool {
        noteProbe(); try beforeProjectProbe?()
        return try wrapped.directoryExistsFollowingLinks(at: path)
    }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func createDirectoryWithoutParents(at path: String) throws { try wrapped.createDirectoryWithoutParents(at: path) }
    func writeFileWithoutParents(at path: String, content: String) throws {
        noteProbe()
        if (path as NSString).lastPathComponent == ".pensieve-project" {
            try beforeMarkerWrite?()
            lock.withLock { markerWrites += 1 }
        }
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
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        wrapped.fileIdentity(at: path, followingLinks: followingLinks)
    }
    func realPath(at path: String) -> String { noteProbe(); return wrapped.realPath(at: path) }
    func resolveRealPath(at path: String) throws -> String { try wrapped.resolveRealPath(at: path) }
    func regularFileMetadata(at path: String) -> RegularFileMetadata? { wrapped.regularFileMetadata(at: path) }
    func touchRegularFile(at path: String, date: Date) throws { try wrapped.touchRegularFile(at: path, date: date) }

    func storeTemporaryParent(root: String) throws -> String { try wrapped.storeTemporaryParent(root: root) }
}
