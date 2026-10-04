import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    func testStoreListingAndEntryReadFailuresRetainOwnershipUntilNextLaunch() throws {
        for kind in ["listing", "entry", "entry-io", "directory-probe", "directory-probe-io", "unsafe-directory"] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(kind))
            defer { try? harness.cleanUp() }
            let skill = try harness.seed()
            harness.context.insert(MachineDeployIntent(machineID: harness.identity.id,
                skillSlug: "skill", platformRaw: "codex"))
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "codex"))
            try harness.context.save()
            try harness.manifest.live.write(harness.manifest.live.snapshot(from: harness.context), toRoot: harness.root)
            let intentBefore = try harness.manifest.read(fromRoot: harness.root).deployIntents
            let rowsBefore = try harness.context.fetch(FetchDescriptor<ScenarioAssignment>()).map(\.id).sorted {
                $0.uuidString < $1.uuidString
            }
            let ledgerBefore = try harness.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.persistentModelID)
            let folder = harness.root + "/skills/skill"
            let parked = harness.root + "/parked-skill"
            if kind == "unsafe-directory" {
                try FileManager.default.moveItem(atPath: folder, toPath: parked)
                try harness.files.createSymlink(at: folder, pointingTo: parked)
            }
            let before = try harness.deployedFiles()
            let faulty = HandoverReadFileService(skillsRoot: harness.root + "/skills", failure: kind)
            XCTAssertFalse(harness.launch(harness.handover(fileService: faulty)).ingestionNeedsRetry)
            try assertReadResult(harness: harness, kind: kind,
                                 expected: ReadExpectation(intents: intentBefore, rows: rowsBefore, ledger: ledgerBefore))
            XCTAssertEqual(harness.manifest.writes, kind == "unsafe-directory" ? 1 : 0, kind)
            XCTAssertEqual(try harness.deployedFiles(), before, kind)
            try harness.assertUnrelatedIntentsUnchanged()
            if kind == "unsafe-directory" {
                try harness.files.deleteFile(at: folder)
                try FileManager.default.moveItem(atPath: parked, toPath: folder)
            }
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            if kind != "unsafe-directory" { try harness.assertComplete() } else {
                try harness.assertComplete([])
            }
            XCTAssertEqual(try harness.deployedFiles(), before, kind)
        }
    }

    private struct ReadExpectation {
        let intents: [DeployIntentRecord]
        let rows: [UUID]
        let ledger: [PersistentIdentifier]
    }

    private func assertReadResult(harness: HandoverHarness, kind: String, expected: ReadExpectation) throws {
        if kind != "unsafe-directory" {
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey), kind)
            XCTAssertNotNil(harness.defaults.object(forKey: ScenarioHandover.activeKey), kind)
            XCTAssertEqual(try harness.freshContext().fetch(FetchDescriptor<ScenarioAssignment>()).map(\.id).sorted {
                $0.uuidString < $1.uuidString
            }, expected.rows, kind)
            XCTAssertEqual(try harness.freshContext().fetch(FetchDescriptor<IntentAssignment>()).map(\.persistentModelID),
                           expected.ledger, kind)
            XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).deployIntents, expected.intents, kind)
            let cached = try harness.manifest.snapshot(from: harness.freshContext()).deployIntents
            XCTAssertEqual(cached.count, expected.intents.count, kind)
            XCTAssertTrue(cached.allSatisfy(expected.intents.contains), kind)
            if kind != "listing" {
                XCTAssertTrue(harness.logs.contains { $0.contains("Deferred:") && $0.contains("skill") }, kind)
            }
        } else {
            XCTAssertTrue(harness.defaults.bool(forKey: ScenarioHandover.doneKey), kind)
            XCTAssertNil(harness.defaults.object(forKey: ScenarioHandover.activeKey), kind)
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 0, kind)
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<IntentAssignment>()), 0, kind)
            XCTAssertTrue(harness.logs.contains { $0.contains("2 left unmanaged") }, kind)
        }
    }
}

/// Forwards I/O to the temporary store; injects whole-folder readability failures, per-entry
/// lookup/read/realpath failures, deploy-path EACCES/EIO and false legacy Boolean probes.
/// No operation falls back to a live user path. Resolution can also model a containment mismatch.
final class HandoverReadFileService: FileServiceProtocol {
    let live = FileService()
    let skillsRoot: String
    let failure: String
    var directoryChecks = 0
    var entryChecks: [String: Int] = [:]
    var folderChecks: [String: Int] = [:]
    var probeError = EACCES
    var listings = 0
    var deployBooleanChecks = 0
    var readlinkChecks = 0
    var resolutionChecks: [String: Int] = [:]
    private var lastResolvedFolder: String?
    init(skillsRoot: String, failure: String) {
        self.skillsRoot = skillsRoot
        self.failure = failure
        probeError = failure.hasSuffix("-io") ? EIO : EACCES
    }
    func readFile(at path: String) throws -> String { try live.readFile(at: path) }
    func writeFile(at path: String, content: String) throws { try live.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try live.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { live.fileExists(at: path) }
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        entryChecks[path, default: 0] += 1
        if failure.hasPrefix("entry"), path.hasPrefix(skillsRoot + "/") {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(probeError))
        }
        if failure == "bad-entry", path == skillsRoot + "/skill" { throw CocoaError(.fileReadNoPermission) }
        if failure == "deploy-probe", path.contains("/agents/codex/") {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(probeError))
        }
        return try live.entryExistsWithoutFollowingLinks(at: path)
    }
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        guard try entryExistsWithoutFollowingLinks(at: path) else { return nil }
        return try live.entryTypeWithoutFollowingLinks(at: path)
    }
    func checkDirectoryReadable(at path: String) throws {
        folderChecks[path, default: 0] += 1
        if path == skillsRoot { directoryChecks += 1 }
        if failure == "listing", path == skillsRoot { throw CocoaError(.fileReadNoPermission) }
        if failure.hasPrefix("directory-probe"), path.hasPrefix(skillsRoot + "/") {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(probeError))
        }
        guard live.directoryExists(at: path) else { throw CocoaError(.fileReadUnknown) }
    }
    func isExecutableFile(at path: String) -> Bool { live.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool {
        if failure == "directory-probe", path.hasPrefix(skillsRoot + "/") { return false }
        return live.directoryExists(at: path)
    }
    func createDirectory(at path: String) throws { try live.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try live.deleteDirectory(at: path) }
    func createSymlink(at path: String, pointingTo target: String) throws { try live.createSymlink(at: path, pointingTo: target) }
    func resolveRealPath(at path: String) throws -> String {
        resolutionChecks[path, default: 0] += 1
        if path.hasPrefix(skillsRoot + "/") { lastResolvedFolder = path }
        if (failure == "resolve-folder" && path == skillsRoot + "/skill")
            || (failure == "resolve-base" && path == skillsRoot && lastResolvedFolder == skillsRoot + "/skill") {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(probeError))
        }
        if failure == "resolve-escape", path == skillsRoot + "/skill" { return skillsRoot + "/../outside" }
        return try live.resolveRealPath(at: path)
    }
    func symlinkTarget(at path: String) throws -> String {
        if path.contains("/agents/") {
            readlinkChecks += 1
            if failure == "readlink" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(probeError)) }
        }
        return try live.symlinkTarget(at: path)
    }
    func isSymlink(at path: String) -> Bool {
        if path.contains("/agents/") {
            deployBooleanChecks += 1
            if failure == "symlink-boolean" { return false }
        }
        return live.isSymlink(at: path)
    }
    func isRegularFile(at path: String) -> Bool {
        if path.contains("/agents/") {
            deployBooleanChecks += 1
            if failure == "regular-boolean" { return false }
        }
        return live.isRegularFile(at: path)
    }
    func listDirectory(at path: String) throws -> [String] {
        listings += 1
        if failure == "listing", path == skillsRoot { throw CocoaError(.fileReadNoPermission) }
        return try live.listDirectory(at: path)
    }
    func contentsHash(at path: String) throws -> String { try live.contentsHash(at: path) }
}
