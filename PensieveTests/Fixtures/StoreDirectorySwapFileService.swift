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
    func writeFile(at path: String, content: String) throws { try wrapped.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isRegularFile(at path: String) -> Bool { wrapped.isRegularFile(at: path) }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}
