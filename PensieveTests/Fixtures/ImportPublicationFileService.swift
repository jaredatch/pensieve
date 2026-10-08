import Foundation
#if !GIT_PROCESS_PROBE
@testable import Pensieve
#endif

/// Forwards fixture I/O to FileService. Write callbacks observe/interfere with the real build before
/// and after SKILL.md is written; they do not simulate publication, locking or cleanup. Used by the
/// import owner and its disposable crash process. Other FileService operations retain their defaults.
final class ImportPublicationFileService: FileServiceProtocol {
    let files = FileService()
    var beforeWrite: (String, String) throws -> Void = { _, _ in }
    var afterWrite: (String, String) throws -> Void = { _, _ in }
    var directoryListings: [String] = []
    func readFile(at path: String) throws -> String { try files.readFile(at: path) }
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String) throws -> RegularFileCopyReceipt {
        try files.copyRegularFiles(fromDirectory: source, toDirectory: destination)
    }
    func writeFile(at path: String, content: String) throws {
        try beforeWrite(path, content)
        try files.writeFile(at: path, content: content)
        try afterWrite(path, content)
    }
    func deleteFile(at path: String) throws { try files.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { files.fileExists(at: path) }
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        try files.entryTypeWithoutFollowingLinks(at: path)
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
    func listDirectory(at path: String) throws -> [String] {
        directoryListings.append(path)
        return try files.listDirectory(at: path)
    }
    func contentsHash(at path: String) throws -> String { try files.contentsHash(at: path) }
}
