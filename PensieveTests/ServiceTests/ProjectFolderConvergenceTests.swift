import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectFolderConvergenceTests: XCTestCase {
    func testLaunchSkipsMissingIntentAndHeadAdvanceDeploysRestoredFolder() throws {
        let harness = try ProjectFolderCallerHarness()
        defer { harness.cleanup() }
        try harness.addIntent()
        var audit: [String] = []
        let convergence = harness.convergence { _, detail in audit.append(detail) }
        convergence.runAfterLaunchIngest()
        XCTAssertTrue(audit.contains("intent:0:0:skipped:1"))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<DeployRecord>()), 0)
        XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/absent"))
        try harness.files.createDirectory(at: harness.project.path)
        audit.removeAll()
        convergence.run(after: .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: false))
        XCTAssertFalse(harness.files.isSymlink(at: harness.artifact(.codex)))
        XCTAssertFalse(audit.contains { $0.hasPrefix("intent:") })
        convergence.run(after: .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: true))
        XCTAssertTrue(harness.files.isSymlink(at: harness.artifact(.codex)))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
        XCTAssertTrue(audit.contains("intent:1:0:skipped:0"))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
    }

    func testHeadAdvanceSkipsMissingCategoryAndLaunchDeploysRestoredFolderForFourAgents() throws {
        let harness = try ProjectFolderCallerHarness()
        defer { harness.cleanup() }
        _ = try harness.addCategory()
        var audit: [String] = []
        let convergence = harness.convergence { _, detail in audit.append(detail) }
        convergence.run(after: .synced(pushed: false, warnings: [], completedAt: Date(), headAdvanced: true))
        XCTAssertTrue(audit.contains("category:0:0:skipped:4"))
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<DeployRecord>()), 0)
        XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/absent"))
        try harness.files.createDirectory(at: harness.project.path)
        convergence.runAfterLaunchIngest()
        for platform in harness.platformVM.installedPlatforms() {
            XCTAssertTrue(harness.platformVM.isDeployed(skill: harness.skill, platform: platform,
                                                         target: .project(harness.project)))
        }
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 4)
        XCTAssertTrue(audit.contains("category:4:0:skipped:0"))
    }

    func testBothLedgersDropDeletedProjectAndRedeployIntoEmptyRestoration() throws {
        for categoryOwned in [false, true] {
            let harness = try ProjectFolderCallerHarness()
            defer { harness.cleanup() }
            if categoryOwned { _ = try harness.addCategory() } else { try harness.addIntent() }
            try harness.files.createDirectory(at: harness.project.path)
            let run = { categoryOwned ? harness.category.reconcile(context: harness.context)
                : harness.intent.reconcile(context: harness.context) }
            XCTAssertEqual(run().successes.count, categoryOwned ? 4 : 1)
            try harness.files.deleteDirectory(at: harness.project.path)
            let missing = run()
            XCTAssertEqual(missing.skipped.count, categoryOwned ? 4 : 1)
            XCTAssertEqual(missing.failureCount, 0)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
            XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.project.path))
            try harness.files.createDirectory(at: harness.project.path)
            XCTAssertEqual(try harness.files.listDirectory(at: harness.project.path), [])
            XCTAssertEqual(run().successes.count, categoryOwned ? 4 : 1)
            XCTAssertTrue(harness.files.isSymlink(at: harness.artifact(.codex)))
            if categoryOwned {
                XCTAssertTrue(harness.platformVM.isDeployed(skill: harness.skill, platform: .cursor,
                                                         target: .project(harness.project)))
            }
        }
    }

    func testLookupFailureFailsAndPreservesBothLedgersWithAndWithoutRealization() throws {
        for categoryOwned in [false, true] {
            for realized in [false, true] {
                let harness = try ProjectFolderCallerHarness()
                defer { harness.cleanup() }
                if categoryOwned { _ = try harness.addCategory() } else { try harness.addIntent() }
                let run = { categoryOwned ? harness.category.reconcile(context: harness.context)
                    : harness.intent.reconcile(context: harness.context) }
                if realized {
                    try harness.files.createDirectory(at: harness.project.path)
                    XCTAssertEqual(run().successes.count, categoryOwned ? 4 : 1)
                }
                let recordsBefore = try harness.context.fetchCount(FetchDescriptor<DeployRecord>())
                let stateBefore = try harness.deployState.read()
                harness.mapped.beforeProjectProbe = { path in
                    if path == harness.project.path { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
                }
                let result = run()
                XCTAssertEqual(result.failureCount, categoryOwned ? 4 : 1)
                XCTAssertEqual(result.skipped.count, 0)
                XCTAssertEqual(result.successes.count, 0)
                for outcome in result.failures {
                    guard case .couldNotCheck? = outcome.projectFolderError else { return XCTFail("Expected lookup failure") }
                    XCTAssertTrue(outcome.error?.contains("couldn't be checked") == true)
                }
                XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()),
                               realized && !categoryOwned ? 1 : 0)
                XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()),
                               realized && categoryOwned ? 4 : 0)
                XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<DeployRecord>()), recordsBefore)
                XCTAssertEqual(try harness.deployState.read().records, stateBefore.records)
                if !realized { XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.root + "/absent")) }
            }
        }
    }

    func testDeletionAfterConvergenceProbeIsSkippedWithoutLedgerForFourAgents() throws {
        let harness = try ProjectFolderCallerHarness()
        defer { harness.cleanup() }
        _ = try harness.addCategory()
        try harness.files.createDirectory(at: harness.project.path)
        var probes = 0
        harness.mapped.beforeProjectProbe = { path in
            guard path == harness.project.path else { return }
            probes += 1
            if probes == 2 { try harness.files.deleteDirectory(at: path) }
        }
        let result = harness.category.reconcile(context: harness.context)
        XCTAssertGreaterThanOrEqual(probes, 2)
        XCTAssertEqual(result.skipped.count, 4)
        XCTAssertEqual(result.failureCount, 0)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        XCTAssertFalse(try harness.files.entryExistsWithoutFollowingLinks(at: harness.project.path))
    }
}
