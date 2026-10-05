import Darwin
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectFolderReviewTests: XCTestCase {
    func testSharedOwnershipRemovalReleasesOnlyItsLedgerForUnavailableProjects() throws {
        for categoryRemoved in [false, true] {
            for unknown in [false, true] {
                let h = try ProjectFolderCallerHarness(installed: [.codex])
                defer { h.cleanup() }
                try h.files.createDirectory(at: h.project.path)
                try h.addIntent()
                let rule = try h.addCategory()
                XCTAssertEqual(h.intent.reconcile(context: h.context).successes.count, 1)
                XCTAssertEqual(h.category.reconcile(context: h.context).successes.count, 1)
                if !unknown { try h.files.deleteDirectory(at: h.project.path) }
                var probes = 0
                h.mapped.beforeProjectProbe = { path in
                    probes += 1
                    if unknown, path == h.project.path {
                        throw ProjectFolderError.couldNotCheck(path: path, reason: "Offline")
                    }
                }
                if categoryRemoved { rule.skillSlugs = [] } else {
                    for intent in try h.context.fetch(FetchDescriptor<MachineDeployIntent>()) { h.context.delete(intent) }
                }
                try h.context.save()
                let result = categoryRemoved ? h.category.reconcile(context: h.context) : h.intent.reconcile(context: h.context)
                XCTAssertTrue(result.outcomes.isEmpty, "Ownership handoff needs no filesystem operation")
                XCTAssertEqual(probes, 0, "Ledger-only ownership removal never probes a project folder")
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), categoryRemoved ? 1 : 0)
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), categoryRemoved ? 0 : 1)
                if unknown { XCTAssertTrue(h.files.isSymlink(at: h.artifact(.codex))) }
            }
        }
    }

    func testProjectListRemovalDoesNotAlertWhenAnotherProjectFails() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        _ = try h.addCategory()
        h.mapped.beforeProjectProbe = { path in
            if path == h.project.path { throw ProjectFolderError.couldNotCheck(path: path, reason: "Offline") }
        }
        var removalError: String?
        let result = ProjectListView.removeProject(h.otherProject, removalError: &removalError) {
            removeRegisteredProject(h.otherProject, categoryStore: CategoryStore(
                manifestService: ManifestService(fileService: h.files), manifestRoot: h.root + "/store"),
                reconciler: h.category, platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: h.context)
        }
        XCTAssertNil(removalError, "Removing B shows no alert when only another project's work fails")
        XCTAssertTrue(result.outcomes.isEmpty, "The caller receives only B's outcomes and unscoped ones")
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.project.id],
                       "B is removed whenever its own removals succeed")
    }

    func testProjectListRemovalKeepsProjectAndAlertsForOwnOrUnscopedFailure() throws {
        for unscoped in [false, true] {
            let h = try ProjectFolderCallerHarness()
            defer { h.cleanup() }
            let failed = BatchPairOutcome(skillID: h.skill.id, skillName: h.skill.name, platform: .codex,
                target: unscoped ? nil : .project(h.otherProject.id), error: "Removal failed")
            let unrelated = BatchPairOutcome(skillID: h.skill.id, skillName: h.skill.name, platform: .codex,
                target: .project(h.project.id), error: "Unrelated failure")
            let reconciler = ProjectListFailureReconciler(result: BatchResult(outcomes: [failed, unrelated]))
            var removalError: String?
            let result = ProjectListView.removeProject(h.otherProject, removalError: &removalError) {
                removeRegisteredProject(h.otherProject, categoryStore: CategoryStore(
                    manifestService: ManifestService(fileService: h.files), manifestRoot: h.root + "/store"),
                    reconciler: reconciler, platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: h.context)
            }
            XCTAssertTrue(removalError?.contains("stays registered") == true,
                          "B's failure or an unscoped failure sets the caller's alert state")
            XCTAssertTrue(try h.context.fetch(FetchDescriptor<Project>()).contains { $0.id == h.otherProject.id },
                          "A failure scoped to B or no project keeps B registered")
            XCTAssertEqual(result.outcomes.count, 1, "The result excludes another project's outcome")
            XCTAssertEqual(result.outcomes.first?.target, failed.target)
        }
    }

    func testUnavailableInSyncPairsHaveNoOutcomesAndKeepBothLedgers() throws {
        for categoryOwned in [false, true] {
            let h = try ProjectFolderCallerHarness()
            defer { h.cleanup() }
            if categoryOwned { _ = try h.addCategory() } else { try h.addIntent() }
            try h.files.createDirectory(at: h.root + "/volume")
            try h.files.createDirectory(at: h.root + "/absent/parent")
            try h.files.createSymlink(at: h.project.path, pointingTo: h.root + "/volume")
            let run = { categoryOwned ? h.category.reconcile(context: h.context) : h.intent.reconcile(context: h.context) }
            XCTAssertEqual(run().successes.count, categoryOwned ? 4 : 1)
            try h.files.deleteFile(at: h.project.path)
            for unknown in [false, true] {
                h.mapped.beforeProjectProbe = { path in
                    guard path == h.project.path else { return }
                    if unknown { throw ProjectFolderError.couldNotCheck(path: path, reason: "Offline") }
                }
                XCTAssertTrue(run().outcomes.isEmpty, "Unavailable in-sync pairs are not pending work")
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), categoryOwned ? 0 : 1)
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), categoryOwned ? 4 : 0)
            }
        }
    }

    func testReturningVolumeWithIntactLinksCanUnassignBothOwners() throws {
        for categoryOwned in [false, true] {
            let h = try ProjectFolderCallerHarness()
            defer { h.cleanup() }
            let category = categoryOwned ? try h.addCategory() : nil
            if !categoryOwned { try h.addIntent() }
            try h.files.createDirectory(at: h.root + "/volume")
            try h.files.createDirectory(at: h.root + "/absent/parent")
            try h.files.createSymlink(at: h.project.path, pointingTo: h.root + "/volume")
            let run = { categoryOwned ? h.category.reconcile(context: h.context) : h.intent.reconcile(context: h.context) }
            XCTAssertEqual(run().successes.count, categoryOwned ? 4 : 1)
            try h.files.deleteFile(at: h.project.path)
            _ = run()
            let intactLink = h.artifact(.codex).replacingOccurrences(of: h.project.path, with: h.root + "/volume")
            XCTAssertTrue(h.files.isSymlink(at: intactLink), "Unmount leaves contents intact")
            try h.files.createSymlink(at: h.project.path, pointingTo: h.root + "/volume")
            if let category { category.skillSlugs = [] } else {
                for row in try h.context.fetch(FetchDescriptor<MachineDeployIntent>()) { h.context.delete(row) }
            }
            try h.context.save()
            XCTAssertFalse(run().hasFailures)
            XCTAssertFalse(h.files.isSymlink(at: h.artifact(.codex)), "Unassignment removes the returning link")
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
        }
    }

    func testUnavailableProjectIsProbedOnceAcrossSkillsForBothOwners() throws {
        for categoryOwned in [false, true] {
            let h = try ProjectFolderCallerHarness()
            defer { h.cleanup() }
            let second = Skill(name: "Second", directoryName: "second")
            h.context.insert(second)
            if categoryOwned {
                let rule = try h.addCategory()
                rule.skillSlugs.append(second.directoryName)
            } else {
                try h.addIntent()
                h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.localID,
                    skillSlug: second.directoryName, platformRaw: "codex", projectKey: h.project.identityKey))
            }
            try h.context.save()
            var probes = 0
            h.mapped.beforeProjectProbe = { path in if path == h.project.path { probes += 1 } }
            let result = categoryOwned ? h.category.reconcile(context: h.context) : h.intent.reconcile(context: h.context)
            XCTAssertEqual(result.skipped.count, categoryOwned ? 8 : 2)
            XCTAssertEqual(probes, 1)
        }
    }

    func testUnregistrationIsNotBlockedByAnotherProjectsPendingLookupFailure() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        _ = try h.addCategory()
        h.mapped.beforeProjectProbe = { path in
            if path == h.project.path { throw ProjectFolderError.couldNotCheck(path: path, reason: "Offline") }
        }
        let result = removeRegisteredProject(h.otherProject, categoryStore: CategoryStore(
            manifestService: ManifestService(fileService: h.files), manifestRoot: h.root + "/store"),
            reconciler: h.category, platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID,
            context: h.context)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<Project>()).map(\.id), [h.project.id])
    }

    func testCategoryActionsReportOnlyNewlyAddedPairs() throws {
        for addingSkill in [false, true] {
            let h = try ProjectFolderCallerHarness()
            defer { h.cleanup() }
            let unrelated = try h.addCategory()
            unrelated.name = "Unrelated"
            let acted = Pensieve.Category(name: "Acted")
            acted.skillSlugs = addingSkill ? [] : [h.skill.directoryName]
            acted.projectKeys = addingSkill ? [h.otherProject.identityKey!] : []
            h.context.insert(acted)
            try h.files.deleteDirectory(at: h.otherProject.path)
            try h.context.save()
            let model = CategoryDetailModel(store: CategoryStore(
                manifestService: ManifestService(fileService: h.files), manifestRoot: h.root + "/store"),
                reconciler: h.category)
            if addingSkill { model.setSkill(h.skill, inCategory: acted, assigned: true, context: h.context) } else {
                model.setProject(h.otherProject, inCategory: acted, member: true, context: h.context)
            }
            let result = try XCTUnwrap(model.lastResult)
            XCTAssertEqual(result.failureCount, 4)
            XCTAssertEqual(result.skipped.count, 4)
            XCTAssertTrue(result.failures.allSatisfy { $0.target == .project(h.otherProject.id) })
        }
    }
}

private struct ProjectListFailureReconciler: CategoryReconcilerProtocol {
    let result: BatchResult
    func reconcile(context: ModelContext) -> BatchResult { result }
}
