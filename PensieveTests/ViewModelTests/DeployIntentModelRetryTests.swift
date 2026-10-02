import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension DeployIntentModelTests {
    func testIdempotentLocalApplySurfacesReadFailureAndRepairsExactTarget() throws {
        let harness = try makeHarness(reconcile: { _ in
            BatchResult.readFailure("deployment state", error: ScenarioStubFailure())
        })
        let skill = try insertSkill(context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: localID, skillSlug: skill.directoryName, platformRaw: PlatformTarget.codex.rawValue
        ))
        try harness.context.save()

        let outcome = try harness.model.apply(
            skills: [skill], platforms: [.codex], selectedMachineIDs: [localID], context: harness.context
        )

        guard case let .localDeploy(result) = outcome else {
            return XCTFail("expected local read failure")
        }
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(result.readFailures.count, 1)
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(harness.linkService.linkCalls.map(\.directoryName), ["alpha"])
    }

    func testIdempotentApplyOfLocallyUninstalledPlatformCreatesNoArtifact() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)

        _ = try harness.model.apply(
            skills: [skill], platforms: [.hermes], selectedMachineIDs: [localID], context: harness.context
        )
        let second = try harness.model.apply(
            skills: [skill], platforms: [.hermes], selectedMachineIDs: [localID], context: harness.context
        )

        XCTAssertEqual(harness.linkService.linkCalls.count, 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        guard case let .localDeploy(result) = second else {
            return XCTFail("expected empty local deploy result")
        }
        XCTAssertTrue(result.outcomes.isEmpty)

        _ = try harness.model.retract(
            skills: [skill], platforms: [.hermes], machineIDs: [localID], context: harness.context
        )
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    func testDeployLocalRetryCreatesMissingAssignment() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        harness.linkService.throwOnLink = [.codex]
        let failed = try harness.model.setSelected(
            true, machineID: localID, skill: skill, platform: .codex, context: harness.context
        )
        XCTAssertEqual(failed?.failures.count, 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        harness.linkService.throwOnLink = []

        let retry = try harness.model.apply(
            skills: [skill], platforms: [.codex], selectedMachineIDs: [localID], context: harness.context
        )

        guard case let .localDeploy(retryResult) = retry else {
            return XCTFail("expected retried local deploy")
        }
        XCTAssertEqual(retryResult.successes.count, 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
        _ = try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [localID], context: harness.context
        )
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
    }

    func testRemoveLocalRetryClearsRetainedAssignment() throws {
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        _ = try harness.model.setSelected(
            true, machineID: localID, skill: skill, platform: .codex, context: harness.context
        )
        harness.linkService.throwOnUnlink = [.codex]
        let failed = try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [localID], context: harness.context
        )
        guard case let .localDeploy(failedResult) = failed else {
            return XCTFail("expected failed local removal")
        }
        XCTAssertEqual(failedResult.failures.count, 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
        harness.linkService.throwOnUnlink = []

        let retry = try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [localID], context: harness.context
        )

        guard case let .localDeploy(retryResult) = retry else {
            return XCTFail("expected retried local removal")
        }
        XCTAssertEqual(retryResult.successes.count, 1)
        XCTAssertEqual(harness.linkService.unlinkCalls.count, 2)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
    }
}
