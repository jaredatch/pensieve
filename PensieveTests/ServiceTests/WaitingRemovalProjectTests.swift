import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalProjectTests: XCTestCase {
    func testMissingProjectWaitsFromEachEvidenceSourceWithoutStateOrIdentity() throws {
        for source in ["category", "intent", "state", "history"] {
            for platform in [PlatformTarget.claudeCode, .cursor] {
                for identity in [false, true] {
                    let h = try WaitingRemovalHarness(platforms: [platform])
                    defer { h.base.cleanup() }
                    if !identity { h.base.project.identityKey = nil }
                    try h.base.files.createDirectory(at: h.base.project.path)
                    let path = h.vm.artifactPath(skill: h.base.skill, platform: platform, target: .project(h.base.project))
                    if platform.usesSymlinks {
                        try LinkService(fileService: h.mapped).link(skill: h.base.skill, platform: platform,
                            projectPath: h.base.project.path)
                    } else {
                        try CursorCompiler(fileService: h.mapped, skillStore: SkillStore(fileService: h.mapped))
                            .compile(skill: h.base.skill, projectPath: h.base.project.path)
                    }
                    try seed(source, platform: platform, path: path, harness: h)
                    try h.base.files.writeFile(at: h.base.project.path + "/notes", content: "Keep my notes")
                    let team = h.base.project.path + "/.cursor/rules/team.mdc"
                    try h.base.files.writeFile(at: team, content: "---\n# pensieve: managed\n---\nTeam rule")
                    try h.hideFolder()
                    let model = ProjectRemovalModel()
                    model.request(h.base.project, platformVM: h.vm, context: h.base.context)
                    XCTAssertTrue(model.preview?.message.contains("will be removed when the folder is back") == true)
                    XCTAssertTrue(model.preview?.message.contains(h.base.project.path) == true)
                    XCTAssertFalse(h.removeProject().hasFailures, "\(source)/\(platform)/\(identity)")
                    let waiting = try h.vm.waitingRemovalStore.read()
                    XCTAssertEqual(waiting.map(\.artifactPath), [path])
                    XCTAssertEqual(waiting.first?.projectIdentityKey, identity ? "github.com/owner/project" : nil)
                    XCTAssertEqual(try h.base.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.base.otherProject.id])
                    XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
                    XCTAssertEqual(try h.base.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
                    XCTAssertTrue(try h.base.deployState.read().records.isEmpty)
                    try h.restoreFolder()
                    _ = h.converge()
                    XCTAssertFalse(try h.base.files.entryExistsWithoutFollowingLinks(at: path))
                    XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
                    XCTAssertEqual(try h.base.files.readFile(at: h.base.project.path + "/notes"), "Keep my notes")
                    XCTAssertEqual(try h.base.files.readFile(at: team), "---\n# pensieve: managed\n---\nTeam rule")
                }
            }
        }
    }

    func testUncheckableProjectUnregistersWithWaitingNoticeThenConvergenceCleans() throws {
        let h = try WaitingRemovalHarness(platforms: [.codex, .cursor])
        defer { h.base.cleanup() }
        try h.deploy([.codex, .cursor])
        h.mapped.beforeProjectProbe = { path in
            if path == h.base.project.path { throw CocoaError(.fileReadNoPermission) }
        }
        let model = ProjectRemovalModel()
        model.request(h.base.project, platformVM: h.vm, context: h.base.context)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.preview?.message.contains(h.base.project.path) == true)
        XCTAssertTrue(model.preview?.message.contains("will be removed when the folder is back") == true)
        XCTAssertFalse(h.removeProject().hasFailures)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 2)
        XCTAssertEqual(try h.base.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.base.otherProject.id])
        XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        XCTAssertFalse(h.vm.reconcileWaitingRemovals(context: h.base.context).hasFailures)
        XCTAssertEqual(try h.vm.waitingRemovalStore.read().count, 2)
        h.mapped.beforeProjectProbe = nil
        _ = h.converge()
        XCTAssertFalse(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        XCTAssertFalse(h.base.files.fileExists(at: h.vm.artifactPath(
            skill: h.base.skill, platform: .cursor, target: .project(h.base.project))))
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
    }

    func testRelativeSavedProjectUnregistersWithoutWaitingRemovals() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        h.base.project.path = "old/relative/project"
        h.base.context.insert(IntentAssignment(skillID: h.base.skill.id, platformRaw: "codex", projectID: h.base.project.id))
        try h.base.context.save()
        // Map the historical relative spelling into the sandbox, including preparation's resolver.
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: h.base.files,
            pathMappings: [(Constants.pensieveSkillsDir, h.base.root + "/store/skills"),
                           (h.base.project.path, h.base.root + "/legacy-relative")], physicalSandbox: h.base.root)
        let vm = PlatformViewModel(fileService: mapped, agentDetection: DeployStubDetection(installed: [.codex]),
            deployStateStore: h.base.deployState)
        let model = ProjectRemovalModel()
        model.request(h.base.project, platformVM: vm, context: h.base.context)
        XCTAssertEqual(model.preview?.artifactCount, 0)
        XCTAssertFalse(model.preview?.message.contains("when the folder is back") == true)
        let result = removeRegisteredProject(h.base.project, reconciler: h.base.category,
            platformVM: vm, localMachineID: ProjectIntentHarness.localID, context: h.base.context)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(try h.base.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.base.otherProject.id])
        XCTAssertTrue(try vm.waitingRemovalStore.read().isEmpty)
    }

    private func seed(_ source: String, platform: PlatformTarget, path: String, harness h: WaitingRemovalHarness) throws {
        switch source {
        case "category": h.base.context.insert(SkillProjectAssignment(
            skillID: h.base.skill.id, projectID: h.base.project.id, platform: platform))
        case "intent": h.base.context.insert(IntentAssignment(
            skillID: h.base.skill.id, platformRaw: platform.rawValue, projectID: h.base.project.id))
        case "history": h.base.context.insert(DeployRecord(skillID: h.base.skill.id, platform: platform,
            targetPath: path, contentHash: "local", projectID: h.base.project.id))
        default: try h.base.deployState.upsert(DeployStateRecord(slug: h.base.skill.directoryName, platform: platform.rawValue,
            scope: "project", projectIdentityKey: h.base.project.identityKey, artifactPath: path, recordedAt: "old"))
        }
        try h.base.context.save()
    }
}
