import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testBulkUnselectBatchesProjectAdmissionAndRefresh() throws {
        for route in ["direct", "unledgered", "ledgered", "category"] {
            do { try verifyBulkUnselect(route: route) } catch { XCTFail("\(route): \(error)") }
        }
    }

    @MainActor
    private func verifyBulkUnselect(route: String) throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        if route == "direct" { project.identityKey = nil }
        let slug = try store.createSkill(name: "Second", description: "Description", body: "# Second")
        let other = Skill(name: "Second", skillDescription: "Description", directoryName: slug)
        harness.context.insert(other)
        let skills = [skill!, other]
        let platforms: Set<PlatformTarget> = [.cursor, .claudeCode]
        let deploy = harness.vm.deployBatch(skills: skills, platforms: Array(platforms),
            target: .project(project), context: harness.context)
        XCTAssertEqual(deploy.successes.count, 4)
        try assertRemovalState(skills: skills, platforms: platforms, project: project, harness: harness, route: route)
        try seedRemovalLedger(route: route, skills: skills, platforms: platforms,
                              project: project, context: harness.context)
        var probes = 0
        mapped.beforeProjectProbe = { path in if path == project.path { probes += 1 } }
        defer { mapped.beforeProjectProbe = nil }
        let refresh = harness.vm.refreshCounter
        let result: BatchResult
        if route == "category" {
            result = CategoryReconciler(platformVM: harness.vm).reconcile(context: harness.context)
        } else {
            let outcome = try secondReviewModel(harness).setProjectSelection(false, skills: skills,
                platforms: platforms, project: project, context: harness.context)
            guard case let .localDeploy(batch) = outcome else {
                XCTFail("Expected local removal for \(route)")
                return
            }
            result = batch
        }
        XCTAssertEqual(result.successes.count, 4, route)
        XCTAssertEqual(probes, 1, route)
        XCTAssertEqual(harness.vm.refreshCounter, refresh + 1, route)
        XCTAssertTrue(try harness.state.read().records.isEmpty, route)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0, route)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0, route)
        for item in skills {
            XCTAssertFalse(try harness.vm.artifactIsOwned(skill: item, platform: .cursor, target: .project(project)))
            XCTAssertFalse(try harness.vm.artifactIsOwned(skill: item, platform: .claudeCode, target: .project(project)))
        }
    }

    @MainActor
    private func assertRemovalState(skills: [Skill], platforms: Set<PlatformTarget>, project: Project,
                                    harness: OwnershipRouteHarness, route: String) throws {
        let paths = Set(skills.flatMap { item in
            platforms.map { harness.vm.artifactPath(skill: item, platform: $0, target: .project(project)) }
        })
        if route == "direct" {
            XCTAssertTrue(try harness.state.read().records.allSatisfy { $0.projectIdentityKey == nil }, route)
        }
        XCTAssertEqual(try harness.state.recordedArtifactPaths(), paths, route)
    }

    @MainActor
    private func seedRemovalLedger(route: String, skills: [Skill], platforms: Set<PlatformTarget>,
                                   project: Project, context: ModelContext) throws {
        for item in skills {
            for platform in platforms {
                if route == "ledgered" {
                    context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID,
                        skillSlug: item.directoryName, platformRaw: platform.rawValue, projectKey: project.identityKey))
                    context.insert(IntentAssignment(skillID: item.id, platformRaw: platform.rawValue, projectID: project.id))
                } else if route == "category" {
                    context.insert(SkillProjectAssignment(skillID: item.id, projectID: project.id, platform: platform))
                }
            }
        }
        try context.save()
        if route == "ledgered" {
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 4, route)
        } else if route == "category" {
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 4, route)
        }
    }

}
