import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testSkillDeletionUsesDirectDeployHistoryWithoutProjectIdentity() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        project.identityKey = nil
        let path = artifactPath(.cursor, project: project.path)
        let result = harness.vm.deployBatch(skills: [skill], platforms: [.cursor],
            target: .project(project), context: harness.context)
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertTrue(try harness.state.read().records.isEmpty)
        XCTAssertTrue(try harness.context.fetch(FetchDescriptor<DeployRecord>()).contains {
            $0.skillID == skill.id && $0.targetPath == path
        })
        let unrecorded = Project(name: "Teammate", path: root + "/teammate")
        harness.context.insert(unrecorded)
        let foreignPath = artifactPath(.cursor, project: unrecorded.path)
        let shared = "---\n# pensieve: managed\n---\nTeammate's rule"
        try mapped.writeFile(at: foreignPath, content: shared)
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
            projects: [project, unrecorded], context: harness.context))
        XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
        XCTAssertEqual(try mapped.readFile(at: foreignPath), shared)
    }

    @MainActor
    func testIntentRetiresAbsentAndForeignPairsWhenDeployStateCannotBeWritten() throws {
        for projectScope in [false, true] {
            for foreign in [false, true] {
                let harness = try contextAndVM()
                let project = reviewProject(harness.context)
                let target: DeployTarget = projectScope ? .project(project) : .userWide
                let path = artifactPath(.cursor, project: target.project?.path)
                if foreign { try mapped.writeFile(at: path, content: "User rule") }
                let statePath = root + "/support/deploy-state.json"
                let newer = #"{"schema_version":2,"records":[]}"#
                try files.writeFile(at: statePath, content: newer)
                harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor",
                    projectID: target.project?.id))
                try harness.context.save()
                let result = reviewIntent(harness.vm).reconcile(context: harness.context)
                XCTAssertTrue(result.outcomes.isEmpty)
                XCTAssertFalse(result.hasFailures)
                XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
                XCTAssertEqual(try files.readFile(at: statePath), newer)
                if foreign {
                    XCTAssertEqual(try mapped.readFile(at: path), "User rule")
                    try mapped.deleteFile(at: path)
                }
            }
        }
    }

    @MainActor
    func testCategoryRemovalDoesNotReportForeignOrAbsentArtifacts() throws {
        for foreign in [false, true] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let path = artifactPath(.cursor, project: project.path)
            if foreign { try mapped.writeFile(at: path, content: "User rule") }
            harness.context.insert(SkillProjectAssignment(skillID: skill.id, projectID: project.id, platform: .cursor))
            try harness.context.save()
            let result = CategoryReconciler(platformVM: harness.vm).reconcile(context: harness.context)
            XCTAssertTrue(result.outcomes.isEmpty)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
            if foreign {
                XCTAssertEqual(try mapped.readFile(at: path), "User rule")
                try mapped.deleteFile(at: path)
            } else { XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path)) }
        }
    }

    @MainActor
    func testRetirementWithoutMatchingStateRecordDoesNotWriteOrRefresh() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        let target = DeployTarget.project(project)
        let path = artifactPath(.cursor, project: project.path)
        try reviewRecord(harness.state, path: path + ".other", target: target)
        let statePath = root + "/support/deploy-state.json"
        let original = "\n" + (try files.readFile(at: statePath)) + "\n"
        try files.writeFile(at: statePath, content: original)
        harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor", projectID: project.id))
        try harness.context.save()
        let refresh = harness.vm.refreshCounter
        XCTAssertTrue(reviewIntent(harness.vm).reconcile(context: harness.context).outcomes.isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(try files.readFile(at: statePath), original)
        XCTAssertEqual(harness.vm.refreshCounter, refresh)
    }

    func testCompilerRefusesForeignSymlinkClassification() throws {
        let path = compiler.outputPath(skill: skill, projectPath: root + "/project")
        let target = root + "/foreign-rule.mdc"
        try files.writeFile(at: target, content: "User rule")
        try mapped.createSymlink(at: path, pointingTo: target)
        XCTAssertThrowsError(try compiler.compile(skill: skill, projectPath: root + "/project")) {
            guard case ArtifactOwnershipError.occupiedPath(let refused) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertEqual(refused, path)
        }
        XCTAssertEqual(try mapped.symlinkTarget(at: path), target)
        XCTAssertEqual(try files.readFile(at: target), "User rule")
    }

    @MainActor
    func testENOTDIRDuringRuleOpenKeepsRemovalRecords() throws {
        for phase in ["header", "legacy", "link"] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let target = DeployTarget.project(project)
            let platform: PlatformTarget = phase == "link" ? .claudeCode : .cursor
            let path = artifactPath(platform, project: project.path)
            try plant(owned: true, legacy: phase == "legacy", platform: platform, path: path, project: project.path)
            let original = platform.usesSymlinks ? try mapped.symlinkTarget(at: path) : try mapped.readFile(at: path)
            try harness.state.replaceAll([])
            try reviewRecord(harness.state, path: path, platform: platform, target: target)
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: platform.rawValue, projectID: project.id))
            try harness.context.save()
            var reads = 0
            mapped.beforeRuleRead = { _ in
                reads += 1
                if reads == (phase == "legacy" ? 2 : 1) {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
                }
            }
            mapped.beforeSymlinkRead = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)) }
            let result = reviewIntent(harness.vm).reconcile(context: harness.context)
            XCTAssertEqual(result.failureCount, 1, phase)
            XCTAssertTrue(result.failures.first?.error?.contains("Could not check ownership") == true, phase)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1, phase)
            XCTAssertEqual(try harness.state.read().records.map(\.artifactPath), [path], phase)
            mapped.beforeRuleRead = nil
            mapped.beforeSymlinkRead = nil
            let after = platform.usesSymlinks ? try mapped.symlinkTarget(at: path) : try mapped.readFile(at: path)
            XCTAssertEqual(after, original, phase)
        }
    }
}
