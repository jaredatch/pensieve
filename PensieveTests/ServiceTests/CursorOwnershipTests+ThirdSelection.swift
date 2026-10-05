import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testBulkUnselectBatchesProjectAdmissionAndRefresh() throws {
        for route in ["direct", "unledgered", "ledgered", "category"] {
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
            try seedRemovalLedger(route: route, skills: skills, platforms: platforms,
                                  project: project, context: harness.context)
            var probes = 0
            mapped.beforeProjectProbe = { path in if path == project.path { probes += 1 } }
            let refresh = harness.vm.refreshCounter
            let result: BatchResult
            if route == "category" {
                result = CategoryReconciler(platformVM: harness.vm).reconcile(context: harness.context)
            } else {
                let outcome = try secondReviewModel(harness).setProjectSelection(false, skills: skills,
                    platforms: platforms, project: project, context: harness.context)
                guard case let .localDeploy(batch) = outcome else { return XCTFail("Expected local removal") }
                result = batch
            }
            XCTAssertEqual(result.successes.count, 4, route)
            XCTAssertEqual(probes, 1, route)
            XCTAssertEqual(harness.vm.refreshCounter, refresh + 1, route)
            XCTAssertTrue(try harness.state.read().records.isEmpty)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
            for item in skills {
                XCTAssertFalse(try harness.vm.artifactIsOwned(skill: item, platform: .cursor, target: .project(project)))
                XCTAssertFalse(try harness.vm.artifactIsOwned(skill: item, platform: .claudeCode, target: .project(project)))
            }
            mapped.beforeProjectProbe = nil
        }
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
    }

}
