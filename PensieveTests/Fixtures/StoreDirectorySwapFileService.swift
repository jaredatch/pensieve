import Foundation
@testable import Pensieve

/// Wraps real fixture I/O and swaps one slug directory after each `isSymlink` probe samples it.
/// Each probe restores the real directory, samples its actual type, then replaces it with an
/// out-of-store link before returning. Repeating the race keeps a later leaf admission from
/// masking a missing realpath guard. Other paths and operations delegate unchanged; this
/// double does not simulate leaf-file races or concurrent threads. All paths belong to the test.
final class StoreDirectorySwapFileService: FileServiceProtocol {
    private let wrapped: FileService
    private let directory: String
    private let outsideDirectory: String
    private let parkedDirectory: String
    private(set) var swapCount = 0
    private(set) var swapError: Error?

    init(wrapped: FileService, directory: String, outsideDirectory: String) {
        self.wrapped = wrapped
        self.directory = directory
        self.outsideDirectory = outsideDirectory
        parkedDirectory = outsideDirectory + "-original"
    }

    func isSymlink(at path: String) -> Bool {
        guard path == directory else { return wrapped.isSymlink(at: path) }
        do {
            let fm = FileManager.default
            if swapCount > 0 {
                try fm.removeItem(atPath: directory)
                try fm.moveItem(atPath: parkedDirectory, toPath: directory)
            }
            let answer = wrapped.isSymlink(at: directory)
            guard !answer else { return answer }
            try fm.moveItem(atPath: directory, toPath: parkedDirectory)
            try fm.createSymbolicLink(atPath: directory, withDestinationPath: outsideDirectory)
            swapCount += 1
            return answer
        } catch {
            swapError = error
            return true
        }
    }

    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
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
    func writeFile(at path: String, content: String) throws { try wrapped.writeFile(at: path, content: content) }
    func writeData(at path: String, data: Data) throws { try wrapped.writeData(at: path, data: data) }
    func writeExecutableFile(at path: String, content: String) throws {
        try wrapped.writeExecutableFile(at: path, content: content)
    }
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        try wrapped.copyFile(at: sourcePath, to: destinationPath)
    }
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String) throws -> RegularFileCopyReceipt {
        try wrapped.copyRegularFiles(fromDirectory: source, toDirectory: destination)
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
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        wrapped.fileIdentity(at: path, followingLinks: followingLinks)
    }
    func realPath(at path: String) -> String { wrapped.realPath(at: path) }
    func resolveRealPath(at path: String) throws -> String { try wrapped.resolveRealPath(at: path) }
    func regularFileMetadata(at path: String) -> RegularFileMetadata? { wrapped.regularFileMetadata(at: path) }
    func touchRegularFile(at path: String, date: Date) throws { try wrapped.touchRegularFile(at: path, date: date) }
}
