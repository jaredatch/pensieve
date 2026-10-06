import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectFolderProbeBoundTests: XCTestCase {
    func testBlockingFixtureHonorsHoldAndExplicitRelease() async throws {
        XCTAssertGreaterThanOrEqual(TestWait.heldFixtureTimeoutSeconds, 2 * TestWait.hostedActionTimeoutSeconds,
                                    "The held-fixture bound must cover both hosted readiness bounds")
        for explicitlyRelease in [false, true] {
            let gate = ProjectFolderBlockingProbe(
                holdTimeoutSeconds: explicitlyRelease ? TestWait.heldFixtureTimeoutSeconds : 0.2 // upper-bound: Hold-expiry test.
            )
            let path = "/nonexistent-pensieve-probe-\(UUID().uuidString)"
            gate.block(path)
            defer { gate.unblock() }
            let worker = Task {
                typealias Timing = (started: TimeInterval, finished: TimeInterval)
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Timing, Error>) in
                    // A blocking fixture belongs on a Dispatch worker, never a cooperative executor thread.
                    DispatchQueue.global().async {
                        let started = ProcessInfo.processInfo.systemUptime
                        do {
                            _ = try gate.probe(path)
                            continuation.resume(returning: (started, ProcessInfo.processInfo.systemUptime))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
            await TestWait.until(failureMessage: "The fixture worker must enter its blocked probe") {
                gate.count(path) == 1
            }
            let releasedAt = ProcessInfo.processInfo.systemUptime
            if explicitlyRelease { gate.unblock() }
            let timing = try await worker.value
            if explicitlyRelease {
                XCTAssertGreaterThanOrEqual(timing.finished, releasedAt, "The probe must stay held until explicit release")
                XCTAssertLessThan(timing.finished - releasedAt, 1, "Explicit release must return promptly after unblock")
            } else {
                let elapsed = timing.finished - timing.started
                XCTAssertGreaterThanOrEqual(elapsed, 0.2, "An unreleased probe must honor its full 0.2-second hold")
                XCTAssertLessThan(elapsed, TestWait.hostedActionTimeoutSeconds,
                                  "The injected hold must expire within the shared bound")
            }
        }
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
