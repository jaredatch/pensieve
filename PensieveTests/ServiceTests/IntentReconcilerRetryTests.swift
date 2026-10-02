import SwiftData
import XCTest
@testable import Pensieve

private final class OneShotDeployPersistFailure {
    var remainingFailures = 1

    func persist(_ context: ModelContext) throws {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw ScenarioStubFailure()
        }
        try context.save()
    }
}

@MainActor
final class IntentReconcilerRetryTests: XCTestCase {
    func testOneCheckoutDeployFailureDoesNotBlockSiblingAndRetries() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("deploy-retry")
        let failing = try harness.insertProject(name: "Failing", path: "/projects/failing", key: "shared")
        let succeeding = try harness.insertProject(name: "Succeeding", path: "/projects/succeeding", key: "shared")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "shared")
        let failingPath = harness.artifactPath(skill: skill, platform: .codex, project: failing)
        harness.linkService.throwOnLinkPaths.insert(failingPath)

        let failed = harness.reconciler.reconcile(context: harness.context)

        XCTAssertEqual(failed.failures.count, 1)
        XCTAssertEqual(failed.successes.count, 1)
        XCTAssertEqual(try harness.assignments().map(\.projectID), [succeeding.id])
        XCTAssertFalse(harness.fileService.symlinks.contains(failingPath))
        XCTAssertTrue(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: succeeding)
        ))

        harness.linkService.throwOnLinkPaths.removeAll()
        let retry = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(retry.hasFailures)
        XCTAssertEqual(retry.successes.count, 1)
        XCTAssertEqual(Set(try harness.assignments().compactMap(\.projectID)), Set([failing.id, succeeding.id]))
        XCTAssertTrue(harness.fileService.symlinks.contains(failingPath))
    }

    func testOneCheckoutRemovalFailureKeepsItsRowAndRetries() throws {
        let harness = try ProjectIntentHarness(installed: [.codex])
        let skill = try harness.insertSkill("remove-retry")
        let failing = try harness.insertProject(name: "Failing", path: "/projects/failing", key: "shared")
        let succeeding = try harness.insertProject(name: "Succeeding", path: "/projects/succeeding", key: "shared")
        let intent = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "shared")
        _ = harness.reconciler.reconcile(context: harness.context)
        harness.context.delete(intent)
        try harness.context.save()
        let failingPath = harness.artifactPath(skill: skill, platform: .codex, project: failing)
        harness.linkService.throwOnUnlinkPaths.insert(failingPath)

        let failed = harness.reconciler.reconcile(context: harness.context)

        XCTAssertEqual(failed.failures.count, 1)
        XCTAssertEqual(failed.successes.count, 1)
        XCTAssertEqual(try harness.assignments().map(\.projectID), [failing.id])
        XCTAssertTrue(harness.fileService.symlinks.contains(failingPath))
        XCTAssertFalse(harness.fileService.symlinks.contains(
            harness.artifactPath(skill: skill, platform: .codex, project: succeeding)
        ))

        harness.linkService.throwOnUnlinkPaths.removeAll()
        let retry = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(retry.hasFailures)
        XCTAssertEqual(retry.successes.count, 1)
        XCTAssertTrue(try harness.assignments().isEmpty)
        XCTAssertFalse(harness.fileService.symlinks.contains(failingPath))
    }

    func testSaveFailureAfterArtifactExistsReportsAndRetriesWithoutLedger() throws {
        let persistence = OneShotDeployPersistFailure()
        let harness = try ProjectIntentHarness(
            installed: [.codex],
            persist: persistence.persist
        )
        let skill = try harness.insertSkill("save-retry")
        let project = try harness.insertProject(name: "Project", path: "/projects/save-retry", key: "key")
        _ = try harness.insertIntent(skill: skill, platformRaw: "codex", projectKey: "key")
        let path = harness.artifactPath(skill: skill, platform: .codex, project: project)

        let failed = harness.reconciler.reconcile(context: harness.context)

        XCTAssertEqual(failed.failures.count, 1)
        XCTAssertTrue(harness.fileService.symlinks.contains(path))
        XCTAssertTrue(try harness.assignments().isEmpty)

        let retry = harness.reconciler.reconcile(context: harness.context)

        XCTAssertFalse(retry.hasFailures)
        XCTAssertEqual(retry.successes.count, 1)
        XCTAssertEqual(try harness.assignments().map(\.projectID), [project.id])
        XCTAssertEqual(harness.linkService.linkCalls.count, 2)
    }
}
