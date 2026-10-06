import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectFolderSecondFixTests: XCTestCase {
    func testUserWideIntentRemovalPreservesForeignRetargetedLink() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: h.files, pathMappings: [
            (logical: Constants.pensieveSkillsDir, physical: h.root + "/store/skills"),
            (logical: Constants.codexUserSkillsDir, physical: h.root + "/user")
        ], physicalSandbox: h.root)
        let vm = PlatformViewModel(fileService: mapped,
            agentDetection: DeployStubDetection(installed: [.codex]), deployStateStore: h.deployState)
        let intent = IntentReconciler(platformVM: vm,
            machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID), handoverIsComplete: { true })
        h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID,
            skillSlug: h.skill.directoryName, platformRaw: PlatformTarget.codex.rawValue))
        try h.context.save()
        XCTAssertEqual(intent.reconcile(context: h.context).successes.count, 1)
        let physical = h.root + "/user/" + h.skill.directoryName
        try h.files.createSymlink(at: physical, pointingTo: h.otherProject.path)
        for row in try h.context.fetch(FetchDescriptor<MachineDeployIntent>()) { h.context.delete(row) }
        try h.context.save()
        XCTAssertEqual(intent.reconcile(context: h.context).successes.count, 0)
        XCTAssertEqual(try h.files.symlinkTarget(at: physical), h.otherProject.path)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
    }

    func testDeploymentsDeselectionPreservesUnledgeredForeignLink() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        let path = h.artifact(.codex)
        try h.files.createSymlink(at: path, pointingTo: h.otherProject.path)
        let result = try h.model().set(false, skill: h.skill, platform: .codex,
            target: .project(h.project), context: h.context)
        XCTAssertEqual(result.successes.count, 0, "There is no owned artifact or ledger row to remove")
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(try h.files.symlinkTarget(at: path), h.otherProject.path)
    }

    func testUnassignmentPreservesForeignLinksForBothProjectOwners() throws {
        for categoryOwned in [false, true] {
            for platform in [PlatformTarget.claudeCode, .grok, .codex] {
                let h = try ProjectFolderCallerHarness(installed: [platform])
                defer { h.cleanup() }
                try h.files.createDirectory(at: h.project.path)
                if categoryOwned { _ = try h.addCategory() } else { try h.addIntent(platform: platform) }
                let run = {
                    categoryOwned ? h.category.reconcile(context: h.context) : h.intent.reconcile(context: h.context)
                }
                XCTAssertEqual(run().successes.count, 1)
                let path = h.artifact(platform)
                try h.files.createSymlink(at: path, pointingTo: h.otherProject.path)
                if categoryOwned {
                    for rule in try h.context.fetch(FetchDescriptor<Pensieve.Category>()) { rule.skillSlugs = [] }
                } else {
                    for row in try h.context.fetch(FetchDescriptor<MachineDeployIntent>()) { h.context.delete(row) }
                }
                try h.context.save()
                let result = run()
                XCTAssertFalse(result.hasFailures)
                XCTAssertEqual(result.successes.count, 0)
                XCTAssertEqual(try h.files.symlinkTarget(at: path), h.otherProject.path)
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
            }
        }
    }

    func testDirectLinkChecksRootBeforeLookingUpProjectArtifact() throws {
        for platform in [PlatformTarget.claudeCode, .grok, .codex] {
            let files = SecondFixPathFiles()
            files.probeError = NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
            let skill = Skill(name: "Skill", directoryName: "skill")
            XCTAssertThrowsError(try LinkService(fileService: files).link(
                skill: skill, platform: platform, projectPath: "/unresponsive/project")) { error in
                guard case ProjectFolderError.couldNotCheck = error else { return XCTFail("Got \(error)") }
            }
            XCTAssertEqual(files.paths, ["/unresponsive/project"], "Admission precedes project-path lookups")
        }
    }

    func testRelativeRemovalAndStatusDoNotAccessDisk() throws {
        let files = SecondFixPathFiles()
        let skill = Skill(name: "Skill", directoryName: "skill")
        let links = LinkService(fileService: files)
        let cursor = CursorCompiler(fileService: files, skillStore: SkillStore(fileService: files, baseDir: "/fixture"))
        for path in ["code/app", "~/code/app", "", "~fixture/code"] {
            for (platform, suffix) in [(PlatformTarget.claudeCode, "/.claude/skills/skill"),
                                      (.grok, "/.grok/skills/skill"), (.codex, "/agents/skill.md")] {
                try links.unlink(skill: skill, platform: platform, projectPath: path)
                XCTAssertFalse(links.isLinked(skill: skill, platform: platform, projectPath: path))
                XCTAssertEqual(links.linkPath(skill: skill, platform: platform, projectPath: path), path + suffix)
            }
            try cursor.remove(skill: skill, projectPath: path)
            XCTAssertFalse(cursor.isUpToDate(skill: skill, projectPath: path))
            XCTAssertEqual(cursor.outputPath(skill: skill, projectPath: path), path + "/.cursor/rules/skill.mdc")
        }
        XCTAssertEqual(files.paths, [], "Relative project operations must make no file-service calls")
    }

    func testMkdirErrorSurvivesInconclusiveInteriorRecheck() throws {
        let lock = NSLock()
        var probes = 0
        let files = FileService(directoryProbe: { _ in
            let count = lock.withLock { probes += 1; return probes }
            if count == 1 { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
        })
        XCTAssertThrowsError(try files.createDirectoryWithoutParents(at: "/fixture/interior", beforeCreate: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        })) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOSPC))
        }
        XCTAssertEqual(lock.withLock { probes }, 2)
    }

    func testAddReusesIdentityAdmissionAndStillRefusesMissingRoot() async throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        var mainProbes = 0
        h.mapped.beforeProjectProbe = { _ in if Thread.isMainThread { mainProbes += 1 } }
        let model = AddProjectModel(fileService: h.mapped, previewDelay: {})
        model.name = "App"
        model.path = h.otherProject.path
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Preview finishes") { !model.isCheckingIdentity }
        XCTAssertNotNil(model.makeProject())
        XCTAssertEqual(mainProbes, 1, "The bounded marker writer reuses identity admission")
        try h.files.deleteDirectory(at: h.otherProject.path)
        mainProbes = 0
        XCTAssertNil(model.makeProject())
        XCTAssertEqual(mainProbes, 1, "Identity refuses a missing folder before marker creation")
        XCTAssertTrue(model.identityMessage?.contains("missing") == true)
        XCTAssertFalse(h.files.fileExists(at: h.otherProject.path))
    }
}

/// Records all required file operations without host I/O. Positive occupants expose accidental
/// relative-path lookups/removals; an injected admission error fences every later lookup.
final class SecondFixPathFiles: FileServiceProtocol {
    var paths: [String] = []
    var probeError: Error?
    var symlinkTargets: [String: String] = [:]
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        paths.append(path)
        return symlinkTargets[path] == nil ? nil : .symlink
    }
    func readFile(at path: String) throws -> String { paths.append(path); return "" }
    func writeFile(at path: String, content: String) throws { paths.append(path) }
    func deleteFile(at path: String) throws { paths.append(path) }
    func fileExists(at path: String) -> Bool { paths.append(path); return true }
    func isExecutableFile(at path: String) -> Bool { paths.append(path); return false }
    func directoryExists(at path: String) -> Bool { paths.append(path); return true }
    func directoryExistsFollowingLinks(at path: String) throws -> Bool {
        paths.append(path)
        if let probeError { throw probeError }
        return true
    }
    func createDirectory(at path: String) throws { paths.append(path) }
    func deleteDirectory(at path: String) throws { paths.append(path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws { paths.append(linkPath) }
    func symlinkTarget(at path: String) throws -> String { paths.append(path); return symlinkTargets[path] ?? "/fixture" }
    func isSymlink(at path: String) -> Bool { paths.append(path); return true }
    func listDirectory(at path: String) throws -> [String] { paths.append(path); return [] }
    func contentsHash(at path: String) throws -> String { paths.append(path); return "" }
}
