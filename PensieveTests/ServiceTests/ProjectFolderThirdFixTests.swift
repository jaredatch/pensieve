import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectFolderThirdFixTests: XCTestCase {
    private let platforms: [PlatformTarget] = [.claudeCode, .grok, .codex, .cursor]
    private let relativePaths = ["code/app", "~/code/app", "", "~fixture/code"]

    func testRelativePathBuildersReturnRecordedPaths() {
        let files = SecondFixPathFiles()
        let skill = Skill(name: "Skill", directoryName: "skill")
        let links = LinkService(fileService: files)
        let cursor = CursorCompiler(fileService: files, skillStore: skillStore())
        for path in relativePaths {
            for platform in platforms {
                let expected = artifact(project: path, slug: skill.directoryName, platform: platform)
                if platform.usesSymlinks {
                    XCTAssertEqual(DeployPaths.linkPath(directoryName: skill.directoryName,
                        platform: platform, projectPath: path), expected)
                    XCTAssertEqual(links.linkPath(skill: skill, platform: platform, projectPath: path), expected)
                } else {
                    XCTAssertEqual(cursor.outputPath(skill: skill, projectPath: path), expected)
                }
            }
        }
        XCTAssertEqual(files.paths, [])
    }

    func testRelativeDeploysFailMissingBeforeDiskAccessForFourAgents() {
        let files = SecondFixPathFiles()
        let skill = Skill(name: "Skill", directoryName: "skill")
        let links = LinkService(fileService: files)
        let cursor = CursorCompiler(fileService: files, skillStore: skillStore())
        for path in relativePaths {
            for platform in platforms {
                XCTAssertThrowsError(try platform.usesSymlinks
                    ? links.link(skill: skill, platform: platform, projectPath: path)
                    : cursor.compile(skill: skill, projectPath: path)) { error in
                    guard case ProjectFolderError.missing(let reported) = error else {
                        return XCTFail("\(platform): expected missing, got \(error)")
                    }
                    XCTAssertEqual(reported, path)
                }
            }
        }
        XCTAssertEqual(files.paths, [], "Refused project deploys make no file operations")
    }

    func testRelativeArtifactPresenceMakesNoDiskCallsForFourAgents() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let files = SecondFixPathFiles()
        let vm = PlatformViewModel(fileService: files,
                                   agentDetection: DeployStubDetection(installed: []), deployStateStore: h.deployState)
        for path in relativePaths {
            h.project.path = path
            for platform in platforms {
                XCTAssertFalse(try vm.removalOperation(
                    skill: h.skill, platform: platform, target: .project(h.project)).classify().isOwned)
            }
        }
        XCTAssertEqual(files.paths, [])
    }

    func testRelativeRemoveBatchRetiresRealRecordedPathsForFourAgents() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let files = SecondFixPathFiles()
        let vm = PlatformViewModel(fileService: files,
                                   agentDetection: DeployStubDetection(installed: []), deployStateStore: h.deployState)
        for path in relativePaths {
            h.project.path = path
            try h.deployState.replaceAll(platforms.map { record(h, platform: $0) })
            let result = vm.removeOwnedBatch(pairs: DeployRemovalPair.expand(skills: [h.skill], platforms: platforms),
                                        target: .project(h.project))
            XCTAssertEqual(result.completedPairs.count, 4)
            XCTAssertFalse(result.hasFailures)
            XCTAssertEqual(try h.deployState.read().records, [], "Real legacy state paths must be retired")
        }
        XCTAssertEqual(files.paths, [], "Deploy-state I/O is separate from project I/O")
    }

    func testRelativeRemoveAllRetiresRealRecordedPathsForThreeLinkAgents() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let files = SecondFixPathFiles()
        let vm = PlatformViewModel(fileService: files, agentDetection: DeployStubDetection(installed: platforms),
                                  deployStateStore: h.deployState)
        for path in relativePaths {
            h.project.path = path
            try h.deployState.replaceAll(platforms.filter(\.usesSymlinks).map { record(h, platform: $0) })
            let result = vm.removeAllDeploys(skill: h.skill, projects: [h.project], localProjectEvidence: {
                try vm.localSkillProjectDeployEvidence(skill: h.skill, projects: [h.project], context: h.context)
            }).batch
            XCTAssertEqual(result.successes.count, 3)
            XCTAssertFalse(result.hasFailures)
            XCTAssertEqual(try h.deployState.read().records, [])
        }
        XCTAssertEqual(files.paths.filter { !$0.hasPrefix("/") }, [], "Relative projects are never probed")
    }

    func testBackfillSkipsRelativeProjectProbesForFourAgents() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        let files = SecondFixPathFiles()
        let paths = DeployStateBackfillPaths(pensieveSkillsDir: h.root + "/store/skills",
            cursorUserRulesDir: h.root + "/cursor", userSkillsRoot: { _ in nil })
        for path in relativePaths {
            h.project.path = path
            for platform in platforms {
                let output = artifact(project: path, slug: h.skill.directoryName, platform: platform)
                files.symlinkTargets[output] = DeployPaths.targetPath(
                    directoryName: h.skill.directoryName, platform: platform, projectPath: path)
                h.context.insert(DeployRecord(skillID: h.skill.id, platform: platform,
                    targetPath: output, contentHash: "legacy", projectID: h.project.id))
            }
            try h.context.save()
            DeployStateBackfill(fileService: files, store: h.deployState, paths: paths).backfill(context: h.context)
            XCTAssertEqual(files.paths, [], "Backfill performs no project probes for a relative root")
            XCTAssertEqual(try h.deployState.read().records, [])
            for record in try h.context.fetch(FetchDescriptor<DeployRecord>()) { h.context.delete(record) }
        }
    }

    func testDirectDeployChecksRootOnceForFourAgents() throws {
        for platform in platforms {
            let h = try ProjectFolderCallerHarness(installed: [platform])
            defer { h.cleanup() }
            try h.files.createDirectory(at: h.project.path)
            var probes: [String] = []
            h.mapped.beforeProjectProbe = { probes.append($0) }
            let result = h.platformVM.deployBatch(skills: [h.skill], platforms: [platform],
                target: .project(h.project), context: h.context)
            XCTAssertEqual(result.successes.count, 1)
            XCTAssertEqual(probes.filter { $0 == h.project.path }.count, 1,
                           "\(platform): a successful deploy admits its root once")
            XCTAssertEqual(probes.first, h.project.path)
        }
    }

    func testSiblingLogsIdentifyStructuredTargetWithBareOrNamedMessage() throws {
        for named in [false, true] {
            let h = try ProjectFolderCallerHarness()
            defer { h.cleanup() }
            let message = (named ? h.project.name + ": " : "") + "Unlink refused"
            let outcome = BatchPairOutcome(skillID: h.skill.id, skillName: h.skill.name, platform: .codex,
                target: .project(h.project.id), error: message)
            var logs: [String] = []
            let result = removeRegisteredProject(h.otherProject,
                reconciler: ThirdFixReconciler(result: BatchResult(outcomes: [outcome])),
                platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: h.context, logFailure: { logs.append($0) })
            XCTAssertFalse(result.hasFailures)
            XCTAssertEqual(logs, [h.project.id.uuidString + ": " + message])
        }
    }

    private func skillStore() -> RecordingDeletionSkillStore {
        let store = RecordingDeletionSkillStore()
        store.bodies["skill"] = "# Body"
        return store
    }

    private func artifact(project: String, slug: String, platform: PlatformTarget) -> String {
        let suffix: String
        switch platform {
        case .claudeCode: suffix = "/.claude/skills/" + slug
        case .grok: suffix = "/.grok/skills/" + slug
        case .codex: suffix = "/agents/" + slug + ".md"
        default: suffix = "/.cursor/rules/" + slug + ".mdc"
        }
        return project + suffix
    }

    private func record(_ h: ProjectFolderCallerHarness, platform: PlatformTarget) -> DeployStateRecord {
        DeployStateRecord(slug: h.skill.directoryName, platform: platform.rawValue, scope: "project",
            projectIdentityKey: h.project.identityKey,
            artifactPath: artifact(project: h.project.path, slug: h.skill.directoryName, platform: platform),
            recordedAt: "2026-01-01T00:00:00Z")
    }
}

private struct ThirdFixReconciler: CategoryReconcilerProtocol {
    func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult {
        reconcile(context: context)
    }

    let result: BatchResult
    func reconcile(context: ModelContext) -> BatchResult { result }
}
