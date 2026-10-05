import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectFolderRoundOneTests: XCTestCase {
    func testSiblingUnlinkFailureIsLoggedWithoutBlockingRemovedProject() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        h.otherProject.identityKey = h.project.identityKey
        _ = try h.addCategory()
        let links = SiblingFailureLinkService(files: h.mapped)
        let vm = PlatformViewModel(fileService: h.mapped, linkService: links,
            agentDetection: DeployStubDetection(installed: [.codex]), deployStateStore: h.deployState)
        let reconciler = CategoryReconciler(platformVM: vm)
        XCTAssertEqual(reconciler.reconcile(context: h.context).successes.count, 2)
        links.failedPath = h.project.path
        var logs: [String] = []
        var alert: String?
        let result = ProjectListView.removeProject(h.otherProject, removalError: &alert) {
            removeRegisteredProject(h.otherProject,
                categoryStore: CategoryStore(manifestService: ManifestService(fileService: h.files),
                    manifestRoot: h.root + "/store"),
                reconciler: reconciler, context: h.context, logFailure: { logs.append($0) })
        }
        XCTAssertNil(alert)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(logs.count, 1, "A sibling failure must leave a log trace")
        XCTAssertEqual(logs.first, h.project.id.uuidString + ": " + h.project.name + ": Sibling unlink refused")
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.project.id])
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<SkillProjectAssignment>()).map(\.projectID), [h.project.id])
        XCTAssertTrue(h.files.isSymlink(at: h.artifact(.codex)))
        links.failedPath = nil
        XCTAssertEqual(reconciler.reconcile(context: h.context).successes.count, 1, "Retained ownership retries the unlink")
        XCTAssertFalse(h.files.isSymlink(at: h.artifact(.codex)))
    }

    func testRelativeSavedProjectIsMissingBeforeAnyDirectoryProbe() throws {
        var paths: [String] = []
        let files = FileService(directoryProbe: { paths.append($0); return true })
        XCTAssertThrowsError(try files.requireProjectDirectory(at: "code/app")) { error in
            guard case ProjectFolderError.missing("code/app") = error else {
                return XCTFail("Expected missing, got \(error)")
            }
        }
        XCTAssertEqual(paths, [])
    }

    func testForeignArtifactsAreNotRealizedAndConvergenceHealsLinksOrReportsOccupied() throws {
        for categoryOwned in [false, true] {
            for platform in [PlatformTarget.claudeCode, .grok, .codex] {
                for occupant in ["file", "directory", "foreign-link"] {
                    let h = try ProjectFolderCallerHarness(installed: [platform])
                    defer { h.cleanup() }
                    try h.files.createDirectory(at: h.project.path)
                    if categoryOwned { _ = try h.addCategory() } else { try h.addIntent(platform: platform) }
                    let run = {
                        categoryOwned ? h.category.reconcile(context: h.context) : h.intent.reconcile(context: h.context)
                    }
                    XCTAssertEqual(run().successes.count, 1)
                    XCTAssertTrue(h.platformVM.artifactExists(skill: h.skill, platform: platform, target: .project(h.project)))
                    let path = h.artifact(platform)
                    try h.files.deleteFile(at: path)
                    switch occupant {
                    case "file": try h.files.writeFile(at: path, content: "Keep")
                    case "directory": try h.files.createDirectory(at: path)
                    default: try h.files.createSymlink(at: path, pointingTo: h.otherProject.path)
                    }
                    XCTAssertFalse(h.platformVM.isDeployed(skill: h.skill, platform: platform, target: .project(h.project)),
                                   "\(platform) / \(occupant) is not a link to the store")
                    XCTAssertEqual(h.platformVM.artifactExists(
                        skill: h.skill, platform: platform, target: .project(h.project)), occupant != "directory",
                        "Removal preserves master's file/link presence check")
                    let result = run()
                    if occupant == "foreign-link" {
                        XCTAssertFalse(result.hasFailures, "Convergence heals the foreign link")
                        XCTAssertEqual(result.successes.count, 1)
                        let expected = LinkService(fileService: h.mapped).targetPath(
                            skill: h.skill, platform: platform, projectPath: h.project.path)
                        XCTAssertEqual(try h.mapped.symlinkTarget(at: path), expected)
                        XCTAssertTrue(h.platformVM.artifactExists(
                            skill: h.skill, platform: platform, target: .project(h.project)))
                        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<DeployRecord>()), 2)
                        XCTAssertTrue(run().outcomes.isEmpty, "The healed pair converges without another deploy")
                    } else {
                        XCTAssertEqual(result.failureCount, 1, "Convergence must report the occupant")
                        XCTAssertTrue(result.failures.first?.error?.contains("already exists") == true)
                        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<DeployRecord>()), 1)
                    }
                    let rows = categoryOwned
                        ? try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>())
                        : try h.context.fetchCount(FetchDescriptor<IntentAssignment>())
                    XCTAssertEqual(rows, 1, "The owner keeps exactly one ledger row")
                    if occupant == "file" { XCTAssertEqual(try h.files.readFile(at: path), "Keep") }
                    if occupant == "directory" { XCTAssertTrue(h.files.directoryExists(at: path)) }
                }
            }
        }
    }

    func testCursorExistingFileStillCountsAsRealized() throws {
        let h = try ProjectFolderCallerHarness(installed: [.cursor])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent(platform: .cursor)
        XCTAssertEqual(h.intent.reconcile(context: h.context).successes.count, 1)
        let compiler = CursorCompiler(fileService: h.mapped, skillStore: SkillStore(fileService: h.files,
            baseDir: h.root + "/store/skills"))
        let path = compiler.outputPath(skill: h.skill, projectPath: h.project.path)
        try h.files.writeFile(at: path, content: "Edited Cursor rule")
        XCTAssertTrue(h.platformVM.artifactExists(skill: h.skill, platform: .cursor, target: .project(h.project)))
        XCTAssertTrue(h.intent.reconcile(context: h.context).outcomes.isEmpty)
        XCTAssertEqual(try h.files.readFile(at: path), "Edited Cursor rule")
    }
}

private final class SiblingFailureLinkService: LinkServiceProtocol {
    let wrapped: LinkService
    var failedPath: String?
    init(files: FileServiceProtocol) { wrapped = LinkService(fileService: files) }
    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        try wrapped.link(skill: skill, platform: platform, projectPath: projectPath)
    }
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        if projectPath == failedPath { throw SiblingUnlinkError() }
        try wrapped.unlink(skill: skill, platform: platform, projectPath: projectPath)
    }
    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        wrapped.isLinked(skill: skill, platform: platform, projectPath: projectPath)
    }
    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        wrapped.linkPath(skill: skill, platform: platform, projectPath: projectPath)
    }
    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        wrapped.targetPath(skill: skill, platform: platform, projectPath: projectPath)
    }
    func validateAll(skills: [Skill]) -> [BrokenLink] { wrapped.validateAll(skills: skills) }
}

private struct SiblingUnlinkError: LocalizedError {
    let errorDescription: String? = "Sibling unlink refused"
}
