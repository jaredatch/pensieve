import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    func testStoreListingAndEntryReadFailuresRetainOwnershipUntilNextLaunch() throws {
        for kind in ["listing", "entry", "directory-probe", "unsafe-directory"] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(kind))
            defer { try? harness.cleanUp() }
            try harness.seed()
            let folder = harness.root + "/skills/skill"
            let parked = harness.root + "/parked-skill"
            if kind == "unsafe-directory" {
                try FileManager.default.moveItem(atPath: folder, toPath: parked)
                try harness.files.createSymlink(at: folder, pointingTo: parked)
            }
            let before = try harness.deployedFiles()
            let faulty = HandoverReadFileService(skillsRoot: harness.root + "/skills", failure: kind)
            XCTAssertFalse(harness.launch(harness.handover(fileService: faulty)).ingestionNeedsRetry)
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey), kind)
            XCTAssertNotNil(harness.defaults.object(forKey: ScenarioHandover.activeKey), kind)
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2, kind)
            XCTAssertEqual(harness.manifest.writes, 0, kind)
            XCTAssertEqual(try harness.deployedFiles(), before, kind)
            try harness.assertUnrelatedIntentsUnchanged()
            if kind == "unsafe-directory" {
                try harness.files.deleteFile(at: folder)
                try FileManager.default.moveItem(atPath: parked, toPath: folder)
            }
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            try harness.assertComplete()
            XCTAssertEqual(try harness.deployedFiles(), before, kind)
        }
    }
}

/// Forwards I/O to the temporary store; injects failures only at listing, no-follow entry lookup,
/// or the legacy Boolean directory probe. No operation falls back to a live user path.
final class HandoverReadFileService: FileServiceProtocol {
    let live = FileService()
    let skillsRoot: String
    let failure: String
    init(skillsRoot: String, failure: String) {
        self.skillsRoot = skillsRoot
        self.failure = failure
    }
    func readFile(at path: String) throws -> String { try live.readFile(at: path) }
    func writeFile(at path: String, content: String) throws { try live.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try live.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { live.fileExists(at: path) }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        if failure == "entry", path.hasPrefix(skillsRoot + "/") { throw CocoaError(.fileReadNoPermission) }
        return try live.entryExistsWithoutFollowingLinks(at: path)
    }
    func isExecutableFile(at path: String) -> Bool { live.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool {
        if failure == "directory-probe", path.hasPrefix(skillsRoot + "/") { return false }
        return live.directoryExists(at: path)
    }
    func createDirectory(at path: String) throws { try live.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try live.deleteDirectory(at: path) }
    func createSymlink(at path: String, pointingTo target: String) throws { try live.createSymlink(at: path, pointingTo: target) }
    func symlinkTarget(at path: String) throws -> String { try live.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { live.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool { live.isRegularFile(at: path) }
    func listDirectory(at path: String) throws -> [String] {
        if failure == "listing", path == skillsRoot { throw CocoaError(.fileReadNoPermission) }
        return try live.listDirectory(at: path)
    }
    func contentsHash(at path: String) throws -> String { try live.contentsHash(at: path) }
}
