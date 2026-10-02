import Foundation
import XCTest
@testable import Pensieve

struct ReverseListingFileService: FileServiceProtocol {
    let wrapped: FileService

    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func writeFile(at path: String, content: String) throws {
        try wrapped.writeFile(at: path, content: content)
    }
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
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] {
        try wrapped.listDirectory(at: path).reversed()
    }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}

struct FailingCopyFileService: FileServiceProtocol {
    struct CopyFailure: Error {}
    let wrapped: FileService
    let failingName: String

    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func writeFile(at path: String, content: String) throws {
        try wrapped.writeFile(at: path, content: content)
    }
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        if (sourcePath as NSString).lastPathComponent == failingName {
            throw CopyFailure()
        }
        try wrapped.copyFile(at: sourcePath, to: destinationPath)
    }
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
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}

final class RecordingVendorFileService: FileServiceProtocol {
    let wrapped: FileService
    private(set) var pathsCreatedBeforeSwap: [String] = []
    private var reachedSwap = false

    init(wrapped: FileService) {
        self.wrapped = wrapped
    }

    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func writeFile(at path: String, content: String) throws {
        try wrapped.writeFile(at: path, content: content)
    }
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        if !reachedSwap {
            pathsCreatedBeforeSwap.append(destinationPath)
        }
        try wrapped.copyFile(at: sourcePath, to: destinationPath)
    }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func createDirectory(at path: String) throws {
        if !reachedSwap {
            pathsCreatedBeforeSwap.append(path)
        }
        try wrapped.createDirectory(at: path)
    }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
    func replaceItem(at path: String, with sourcePath: String) throws {
        reachedSwap = true
        try wrapped.replaceItem(at: path, with: sourcePath)
    }
}

final class SwapSourceOnRegularCheckFileService: FileServiceProtocol {
    let wrapped: FileService
    let source: String
    let symlinkTarget: String
    private(set) var sourceRegularChecks = 0

    init(wrapped: FileService, source: String, symlinkTarget: String) {
        self.wrapped = wrapped
        self.source = source
        self.symlinkTarget = symlinkTarget
    }

    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func writeFile(at path: String, content: String) throws {
        try wrapped.writeFile(at: path, content: content)
    }
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
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool {
        let wasRegular = wrapped.isRegularFile(at: path)
        if path == source, wasRegular {
            sourceRegularChecks += 1
            try? wrapped.deleteFile(at: path)
            try? wrapped.createSymlink(at: path, pointingTo: symlinkTarget)
        }
        return wasRegular
    }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}

final class CrashManifest: ManifestReadWriting {
    enum FailurePoint {
        case beforeUpsert
        case afterUpsert
    }

    struct InjectedFailure: Error {}
    let wrapped: ManifestService
    let failurePoint: FailurePoint

    init(wrapped: ManifestService, failurePoint: FailurePoint) {
        self.wrapped = wrapped
        self.failurePoint = failurePoint
    }

    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        try wrapped.write(snapshot, toRoot: root)
    }

    func read(fromRoot root: String) throws -> ManifestSnapshot {
        try wrapped.read(fromRoot: root)
    }

    func upsertSkillOverlay(_ overlay: SkillOverlay, toRoot root: String) throws {
        if failurePoint == .beforeUpsert { throw InjectedFailure() }
        try wrapped.upsertSkillOverlay(overlay, toRoot: root)
        throw InjectedFailure()
    }
}

extension SkillInstallServiceTests {
    func testCopyFileDoesNotUseASeparateRegularFilePathCheck() throws {
        let source = tempDir + "/swap-source"
        let target = tempDir + "/swap-target"
        let destination = tempDir + "/swap-destination"
        try fileService.writeFile(at: source, content: "source bytes")
        try fileService.writeFile(at: target, content: "target bytes")
        let swapping = SwapSourceOnRegularCheckFileService(
            wrapped: fileService,
            source: source,
            symlinkTarget: target
        )

        try swapping.copyFile(at: source, to: destination)

        XCTAssertEqual(swapping.sourceRegularChecks, 0)
        XCTAssertFalse(fileService.isSymlink(at: destination))
        XCTAssertEqual(try fileService.readFile(at: destination), "source bytes")
    }
}
