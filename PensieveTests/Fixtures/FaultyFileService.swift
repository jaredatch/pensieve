import Foundation
@testable import Pensieve

/// Wraps a real `FileService`, optionally throwing for one `readFile` path and/or one `listDirectory`
/// path — models transient I/O on a present file or an existing directory.
struct FaultyFileService: FileServiceProtocol {
    struct Boom: Error {}
    let wrapped: FileService
    var failReadPath: String?
    var failListPath: String?

    func readFile(at path: String) throws -> String {
        if path == failReadPath { throw Boom() }
        return try wrapped.readFile(at: path)
    }
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        if path == failReadPath { throw Boom() }
        return try wrapped.readRegularFileData(at: path, maximumBytes: maximumBytes)
    }
    func writeFile(at path: String, content: String) throws { try wrapped.writeFile(at: path, content: content) }
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
    func listDirectory(at path: String) throws -> [String] {
        if path == failListPath { throw Boom() }
        return try wrapped.listDirectory(at: path)
    }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}
