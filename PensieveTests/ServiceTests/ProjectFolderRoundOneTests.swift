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
        let category = try h.addCategory()
        category.projectKeys.append(h.otherProject.identityKey!)
        let links = SiblingFailureLinkService(files: h.mapped)
        let vm = PlatformViewModel(fileService: h.mapped, linkService: links,
            agentDetection: DeployStubDetection(installed: [.codex]), deployStateStore: h.deployState)
        let reconciler = CategoryReconciler(platformVM: vm)
        XCTAssertEqual(reconciler.reconcile(context: h.context).successes.count, 2)
        // The other project already has a pending category unlink; removal must log its failure.
        category.projectKeys.removeAll { $0 == h.project.identityKey }
        try h.context.save()
        links.failedPath = h.project.path
        var logs: [String] = []
        let model = ProjectRemovalModel()
        model.request(h.otherProject, platformVM: vm, context: h.context)
        let result = model.confirm { _, plan in
            removeRegisteredProject(h.otherProject,
                reconciler: reconciler, manifestService: ManifestService(fileService: h.files),
                    manifestRoot: h.root + "/store", platformVM: vm, localMachineID: ProjectIntentHarness.localID,
                    confirmedPreview: plan,
            context: h.context, logFailure: { logs.append($0) })
        }
        let alert = model.error
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

    func testForeignArtifactsAreNotRealizedAndConvergenceReportsOccupied() throws {
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
                    XCTAssertTrue(try h.platformVM.removalOperation(
                        skill: h.skill, platform: platform, target: .project(h.project)).classify().isOwned)
                    let path = h.artifact(platform)
                    try h.files.deleteFile(at: path)
                    switch occupant {
                    case "file": try h.files.writeFile(at: path, content: "Keep")
                    case "directory": try h.files.createDirectory(at: path)
                    default: try h.files.createSymlink(at: path, pointingTo: h.otherProject.path)
                    }
                    XCTAssertFalse(h.platformVM.isDeployed(skill: h.skill, platform: platform, target: .project(h.project)),
                                   "\(platform) / \(occupant) is not a link to the store")
                    XCTAssertFalse(try h.platformVM.removalOperation(
                        skill: h.skill, platform: platform, target: .project(h.project)).classify().isOwned)
                    let result = run()
                    XCTAssertEqual(result.failureCount, 1, "Convergence must report the occupant")
                    XCTAssertTrue(result.failures.first?.error?.contains("already exists") == true)
                    XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<DeployRecord>()), 1)
                    if occupant == "foreign-link" {
                        XCTAssertEqual(try h.files.symlinkTarget(at: path), h.otherProject.path)
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

    func testCursorForeignFileFailsConvergence() throws {
        let h = try ProjectFolderCallerHarness(installed: [.cursor])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        try h.addIntent(platform: .cursor)
        XCTAssertEqual(h.intent.reconcile(context: h.context).successes.count, 1)
        let compiler = CursorCompiler(fileService: h.mapped, skillStore: SkillStore(fileService: h.files,
            baseDir: h.root + "/store/skills"))
        let path = compiler.outputPath(skill: h.skill, projectPath: h.project.path)
        try h.files.writeFile(at: path, content: "Edited Cursor rule")
        XCTAssertFalse(try h.platformVM.removalOperation(
            skill: h.skill, platform: .cursor, target: .project(h.project)).classify().isOwned)
        XCTAssertEqual(h.intent.reconcile(context: h.context).failureCount, 1)
        XCTAssertEqual(try h.files.readFile(at: path), "Edited Cursor rule")
    }
}

private final class SiblingFailureLinkService: LinkServiceProtocol {
    let wrapped: LinkService
    var failedPath: String?
    func removalOperation(skill: Skill, platform: PlatformTarget,
                          projectPath: String?) -> DeployRemovalOperation {
        let operation = wrapped.removalOperation(skill: skill, platform: platform, projectPath: projectPath)
        return DeployRemovalOperation(classify: operation.classify, delete: {
            if projectPath == self.failedPath { throw SiblingUnlinkError() }
            return try operation.delete()
        })
    }
    init(files: FileServiceProtocol) { wrapped = LinkService(fileService: files) }
    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        try wrapped.link(skill: skill, platform: platform, projectPath: projectPath)
    }
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        if projectPath == failedPath { throw SiblingUnlinkError() }
        return try wrapped.unlink(skill: skill, platform: platform, projectPath: projectPath)
    }
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        try wrapped.ownsArtifact(skill: skill, platform: platform, projectPath: projectPath)
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
