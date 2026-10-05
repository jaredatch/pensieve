import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testMissingSourceDoesNotBlockDeletionOrIntentRemovalForUserRules() throws {
        for deletion in [false, true] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let targets: [DeployTarget] = [.userWide, .project(project)]
            let text = "---\ndescription: My rule\n---\nKeep my bytes"
            for target in targets {
                let path = artifactPath(.cursor, project: target.project?.path)
                try mapped.writeFile(at: path, content: text)
                try reviewRecord(harness.state, path: path, target: target)
                harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor", projectID: target.project?.id))
            }
            try harness.context.save()
            try files.deleteFile(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md")
            if deletion {
                XCTAssertTrue(reviewDelete(harness, project: project))
                XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 0)
            } else {
                XCTAssertFalse(reviewIntent(harness.vm).reconcile(context: harness.context).hasFailures)
            }
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertTrue(try harness.state.read().records.isEmpty)
            for target in targets {
                XCTAssertEqual(try mapped.readFile(at: artifactPath(.cursor, project: target.project?.path)), text)
            }
            try store.writeBody(directoryName: skill.directoryName, body: "# Body")
        }
    }

    @MainActor
    func testFileParentsMeanAbsentForDeletionAndStillFailDeploy() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        for name in [".cursor", "agents", ".grok", ".claude"] {
            try files.writeFile(at: project.path + "/" + name, content: "User file")
        }
        for platform in PlatformTarget.allCases.filter(\.supportsProjectScope) {
            let path = artifactPath(platform, project: project.path)
            let parent = try XCTUnwrap(path.dropFirst(project.path.count + 1).split(separator: "/").first)
            var writerError: Error?
            do { try files.createDirectoryWithoutParents(at: project.path + "/" + parent) } catch { writerError = error }
            let result = harness.vm.deployBatch(skills: [skill], platforms: [platform], target: .project(project),
                                                context: harness.context)
            XCTAssertEqual(result.failureCount, 1)
            XCTAssertEqual(result.failures.first?.error,
                BatchPairOutcome.failureMessage(try XCTUnwrap(writerError), target: .project(project)))
        }
        XCTAssertTrue(reviewDelete(harness, project: project))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 0)
        for name in [".cursor", "agents", ".grok", ".claude"] {
            XCTAssertEqual(try files.readFile(at: project.path + "/" + name), "User file")
        }
    }

    @MainActor
    func testSkillDeletionRequiresLocalRecordForProjectCursorRule() throws {
        for recorded in [false, true] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let target = DeployTarget.project(project)
            let path = artifactPath(.cursor, project: project.path)
            let text = "---\n# pensieve: managed\n---\nTeammate's committed rule"
            try mapped.writeFile(at: path, content: text)
            if recorded { try reviewRecord(harness.state, path: path, target: target) }
            XCTAssertTrue(reviewDelete(harness, project: project))
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 0)
            if recorded {
                XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
            } else {
                XCTAssertEqual(try mapped.readFile(at: path), text)
            }
            XCTAssertTrue(try harness.state.read().records.isEmpty)
            try files.writeFile(at: root + "/store/skills/" + skill.directoryName + "/SKILL.md", content: "# Body")
        }
    }

    func testForeignLinkRefusalUsesOneTypedClassification() throws {
        for state in [LinkServiceScriptedPathState.retargetedDirectorySymlink, .realFile] {
            let path = DeployPaths.linkPath(directoryName: skill.directoryName, platform: .claudeCode, projectPath: nil)
            let scripted = LinkServiceScriptedFileService(linkPath: path,
                canonicalDirectory: Constants.pensieveSkillsDir + "/" + skill.directoryName, state: state)
            scripted.failRepeatedEntryProbe = true
            XCTAssertThrowsError(try LinkService(fileService: scripted).link(skill: skill, platform: .claudeCode,
                                                                            projectPath: nil)) { error in
                if state.isSymlink {
                    guard case ArtifactOwnershipError.occupiedPath(let occupied) = error else {
                        return XCTFail("Expected typed ownership refusal, got \(error)")
                    }
                    XCTAssertEqual(occupied, path)
                } else {
                    guard case LinkError.occupiedByRealPath(let occupied) = error else {
                        return XCTFail("Expected typed real-path refusal, got \(error)")
                    }
                    XCTAssertEqual(occupied, path)
                }
            }
            XCTAssertEqual(scripted.entryTypeProbeCount, 1)
            XCTAssertFalse(scripted.createSymlinkCalled)
        }
    }

    @MainActor
    private func reviewDelete(_ harness: OwnershipRouteHarness, project: Project) -> Bool {
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        return SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
                                        projects: [project], context: harness.context)
    }
}
