import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectFolderProbeBoundTests: XCTestCase {
    func testBlockingFixtureStaysHeldAcrossReadinessHandoffs() async {
        let gate = ProjectFolderBlockingProbe()
        let path = TestTemporaryDirectory.path + "held-probe-" + UUID().uuidString
        gate.block(path)
        defer { gate.unblock() }
        let returned = DispatchSemaphore(value: 0)
        let probe = Task.detached {
            _ = try? gate.probe(path)
            returned.signal()
        }
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "The blocking fixture must enter its hold") { gate.count(path) == 1 }
        let outcome = await Task.detached {
            returned.wait(timeout: .now() + 5) // upper-bound: Observe the hold beyond its former four-second expiry.
        }.value
        XCTAssertEqual(outcome, .timedOut, "The fixture must stay held across both readiness handoffs")
        gate.unblock()
        await probe.value
    }

    func testConvergenceBoundsBlockedProbeRetainsRowsAndDeploysOtherProjectsForBothOwners() throws {
        for categoryOwned in [false, true] {
            let gate = ProjectFolderBlockingProbe()
            let files = FileService(directoryProbe: gate.probe)
            let h = try ProjectFolderCallerHarness(installed: [.codex], files: files)
            defer { gate.unblock(); h.cleanup() }
            try files.createDirectory(at: h.project.path)
            if categoryOwned { _ = try h.addCategory() } else { try h.addIntent() }
            let run = { categoryOwned ? h.category.reconcile(context: h.context) : h.intent.reconcile(context: h.context) }
            XCTAssertEqual(run().successes.count, 1)
            if categoryOwned {
                let rule = try XCTUnwrap(h.context.fetch(FetchDescriptor<Pensieve.Category>()).first)
                rule.projectKeys = [h.otherProject.identityKey!]
            } else {
                for row in try h.context.fetch(FetchDescriptor<MachineDeployIntent>()) { h.context.delete(row) }
                try h.addIntent(project: h.otherProject)
            }
            try h.context.save()
            gate.block(h.project.path)
            let before = gate.count(h.project.path)
            let start = Date()
            let first = run()
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 3, "The project probe must stop waiting at about two seconds")
            XCTAssertEqual(first.failureCount, 1)
            XCTAssertEqual(first.skipped.count, 0)
            XCTAssertTrue(first.failures.first?.error?.contains("couldn't be checked") == true)
            XCTAssertEqual(first.successes.count, 1, "Other projects still deploy")
            XCTAssertTrue(files.isSymlink(at: h.artifact(.codex)), "Uncheckable folders receive no writes")
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), categoryOwned ? 0 : 2)
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), categoryOwned ? 2 : 0)
            let retryStart = Date()
            let retry = run()
            XCTAssertLessThan(Date().timeIntervalSince(retryStart), 0.5, "An outstanding probe is refused immediately")
            XCTAssertEqual(retry.failureCount, 1)
            XCTAssertEqual(gate.count(h.project.path), before + 1, "Only one raw probe may remain outstanding")
        }
    }

    func testPreviewAndAddShareBoundAndOutstandingProbe() async throws {
        let gate = ProjectFolderBlockingProbe()
        let files = FileService(directoryProbe: gate.probe)
        let h = try ProjectFolderCallerHarness(files: files)
        defer { gate.unblock(); h.cleanup() }
        gate.block(h.otherProject.path)
        let model = AddProjectModel(fileService: h.mapped, previewDelay: {})
        model.name = "App"
        let start = Date()
        model.path = h.otherProject.path
        await TestWait.until(timeout: .seconds(5), // upper-bound: Three-second elapsed assertion below.
                             failureMessage: "Preview must finish checking a stalled folder") {
            !model.isCheckingIdentity
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(model.identityMessage?.contains("couldn't be checked") == true)
        XCTAssertFalse(model.isValid)
        let anotherInstance = FileService(directoryProbe: gate.probe)
        XCTAssertThrowsError(try anotherInstance.requireProjectDirectory(at: h.otherProject.path))
        let addStart = Date()
        XCTAssertNil(model.makeProject())
        XCTAssertLessThan(Date().timeIntervalSince(addStart), 0.5)
        XCTAssertEqual(gate.count(h.otherProject.path), 1)
        XCTAssertFalse(files.fileExists(at: h.otherProject.path + "/.pensieve-project"))
    }
}
