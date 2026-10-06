import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension DeployIntentModelTests {
    func testCriterionAIntentFileExistsAtEachDeployAndCombinesScopes() throws {
        var nudges = 0
        let harness = try makeHarness(notifier: { nudges += 1 })
        let skill = try insertSkill(context: harness.context)
        let project = try insertCriteriaProject("one", context: harness.context)
        let service = ManifestService(fileService: harness.manifestFileService)
        var expectProject = false
        var checkedDeploys = 0
        harness.linkService.onLink = {
            let records = try? service.read(fromRoot: harness.root).deployIntents
            XCTAssertEqual(records?.contains(where: { $0.projectKey == nil }), true)
            XCTAssertEqual(records?.contains(where: { $0.projectKey == project.identityKey }), expectProject)
            checkedDeploys += 1
        }

        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        expectProject = true
        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .project(project), context: harness.context
        )

        XCTAssertEqual(checkedDeploys, 2)
        XCTAssertEqual(nudges, 2)
        let path = criteriaIntentPath(harness, skill: skill)
        XCTAssertTrue(harness.manifestFileService.fileExists(at: path))
        let records = try service.read(fromRoot: harness.root).deployIntents
        XCTAssertEqual(records.filter { $0.skillSlug == skill.directoryName }.count, 2)
    }

    func testCriterionBRetractionPreservesOtherEntriesDeletesLastFileAndNudges() throws {
        var nudges = 0
        let harness = try makeHarness(notifier: { nudges += 1 })
        let skill = try insertSkill(context: harness.context)
        let one = try insertCriteriaProject("one", context: harness.context)
        let two = try insertCriteriaProject("two", context: harness.context)
        for target in [DeployTarget.userWide, .project(one), .project(two)] {
            _ = try harness.model.set(
                true, skill: skill, platform: .codex, target: target, context: harness.context
            )
        }
        let service = ManifestService(fileService: harness.manifestFileService)
        let path = criteriaIntentPath(harness, skill: skill)
        nudges = 0

        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .project(one), context: harness.context
        )
        var records = try service.read(fromRoot: harness.root).deployIntents
        XCTAssertTrue(records.contains { $0.projectKey == nil })
        XCTAssertTrue(records.contains { $0.projectKey == two.identityKey })
        XCTAssertFalse(records.contains { $0.projectKey == one.identityKey })
        XCTAssertTrue(harness.manifestFileService.fileExists(at: path))

        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .project(two), context: harness.context
        )
        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        records = try service.read(fromRoot: harness.root).deployIntents
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(harness.manifestFileService.fileExists(at: path))
        XCTAssertEqual(nudges, 3)
    }

    func testCriterionCIntentlessCategoryDeployTurnsOffWithoutWritingIntent() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        let project = try insertCriteriaProject("category", context: harness.context)
        harness.linkService.fileService.directories.insert(project.path)
        harness.platformVM.deploy(
            skill: skill, platform: .codex, target: .project(project), context: harness.context
        )
        harness.context.insert(SkillProjectAssignment(
            skillID: skill.id, projectID: project.id, platform: .codex
        ))
        try harness.context.save()

        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .project(project), context: harness.context
        )

        XCTAssertFalse(try harness.platformVM.artifactIsOwned(
            skill: skill, platform: .codex, target: .project(project)
        ))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertFalse(harness.manifestFileService.fileExists(at: criteriaIntentPath(harness, skill: skill)))
    }

    func testCriterionHKeylessAndInvalidProjectsLeaveEveryManifestByteUnchanged() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        let keyless = Project(name: "Keyless", path: "/tmp/keyless")
        let invalid = Project(name: "Invalid", path: "/tmp/invalid")
        invalid.identityKey = " leading-space"
        harness.context.insert(keyless)
        harness.context.insert(invalid)
        try harness.context.save()
        try writeCriteriaManifest(harness)
        let before = try criteriaManifestBytes(root: harness.root)

        for project in [keyless, invalid] {
            _ = try harness.model.set(
                true, skill: skill, platform: .codex, target: .project(project), context: harness.context
            )
            XCTAssertEqual(try criteriaManifestBytes(root: harness.root), before)
            _ = try harness.model.set(
                false, skill: skill, platform: .codex, target: .project(project), context: harness.context
            )
            XCTAssertEqual(try criteriaManifestBytes(root: harness.root), before)
        }
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    func testCriterionIMacRetractionKeepsProjectIntentDeployAndOtherProjectsUntouched() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        let intended = try insertCriteriaProject("intended", context: harness.context)
        let other = try insertCriteriaProject("other", context: harness.context)
        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .project(intended), context: harness.context
        )
        harness.platformVM.deploy(
            skill: skill, platform: .codex, target: .project(other), context: harness.context
        )
        let service = ManifestService(fileService: harness.manifestFileService)
        let beforeProjects = try service.read(fromRoot: harness.root).deployIntents.filter { $0.projectKey != nil }
        harness.linkService.unlinkCalls.removeAll()

        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )

        let after = try service.read(fromRoot: harness.root).deployIntents
        XCTAssertEqual(after.filter { $0.projectKey != nil }, beforeProjects)
        XCTAssertFalse(after.contains { $0.projectKey == nil })
        XCTAssertTrue(harness.platformVM.isDeployed(
            skill: skill, platform: .codex, target: .project(intended)
        ))
        XCTAssertTrue(harness.platformVM.isDeployed(
            skill: skill, platform: .codex, target: .project(other)
        ))
        XCTAssertEqual(harness.linkService.unlinkCalls.map(\.projectPath), [nil])
    }

    func testCriterionJSheetUserWideOperationsPreserveProjectEntriesOnDisk() throws {
        let harness = try makeHarness()
        let alpha = try insertSkill(context: harness.context)
        let beta = Skill(name: "Beta", directoryName: "beta")
        let project = try insertCriteriaProject("sheet", context: harness.context)
        harness.context.insert(beta)
        try harness.context.save()
        _ = try harness.model.setProjectSelection(
            true, skills: [alpha, beta], platforms: [.codex], project: project, context: harness.context
        )
        let service = ManifestService(fileService: harness.manifestFileService)
        let before = try service.read(fromRoot: harness.root).deployIntents.filter { $0.projectKey != nil }

        _ = try harness.model.apply(
            skills: [alpha, beta], platforms: [.codex], selectedMachineIDs: [localID],
            context: harness.context
        )
        XCTAssertEqual(
            try service.read(fromRoot: harness.root).deployIntents.filter { $0.projectKey != nil }, before
        )
        _ = try harness.model.retract(
            skills: [alpha, beta], platforms: [.codex], machineIDs: [localID], context: harness.context
        )
        XCTAssertEqual(
            try service.read(fromRoot: harness.root).deployIntents.filter { $0.projectKey != nil }, before
        )
    }
}

@MainActor
private extension DeployIntentModelTests {
    func insertCriteriaProject(_ suffix: String, context: ModelContext) throws -> Project {
        let project = Project(name: suffix.capitalized, path: "/tmp/" + suffix)
        project.identityKey = "github.com/owner/" + suffix
        context.insert(project)
        try context.save()
        return project
    }

    func criteriaIntentPath(_ harness: Harness, skill: Skill) -> String {
        harness.root + "/manifest/deploys/" + localID + "/" + skill.directoryName + ".yaml"
    }

    func writeCriteriaManifest(_ harness: Harness) throws {
        let service = ManifestService(fileService: harness.manifestFileService)
        try service.write(try service.snapshot(from: harness.context), toRoot: harness.root)
    }

    func criteriaManifestBytes(root: String) throws -> [String: Data] {
        let manifestRoot = root + "/manifest"
        guard let enumerator = FileManager.default.enumerator(atPath: manifestRoot) else { return [:] }
        var result: [String: Data] = [:]
        for case let relative as String in enumerator {
            let path = manifestRoot + "/" + relative
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            result[relative] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return result
    }
}
