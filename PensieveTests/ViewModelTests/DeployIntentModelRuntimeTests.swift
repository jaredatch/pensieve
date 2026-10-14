import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension DeployIntentModelTests {
    func assertRuntimeDeploymentNudges() async throws {
        let h = try CLIDeployFixture()
        let scheduler = SyncScheduler(debounceSeconds: 0, startAutomatically: false, backgroundSyncEnabled: { true })
        let runtime = try AppRuntime(container: h.context.container, platformVM: h.platform, scheduler: scheduler,
            paths: AppRuntimePaths(storeRoot: h.root, appSupportDir: h.directory.path))
        var drains = 0
        scheduler.installDrain { _ in drains += 1 }
        scheduler.coordinatorBecameReady()
        scheduler.launchIngestCompleted()
        await TestWait.until(failureMessage: "Initial scheduler request did not drain") { drains == 1 && !scheduler.isSyncing }
        let window = DeployIntentModel(service: runtime.deployMutations)
        let cli = CLIDeployHandler(service: runtime.deployMutations, files: h.directory.files)
        for (index, command) in ["window deploy", "window undeploy", "deploy", "undeploy"].enumerated() {
            if command.hasPrefix("window") {
                _ = try window.set(command == "window deploy", skill: h.skill, platform: .claudeCode,
                    target: .userWide, context: h.context)
            } else {
                XCTAssertTrue(cli.handle(h.request(command), context: h.context).envelope.ok)
            }
            await TestWait.until(timeout: .seconds(2), // upper-bound: zero-debounce scheduler callback, no network work
                failureMessage: "Runtime did not nudge sync after \(command)") { drains == index + 2 && !scheduler.isSyncing }
            XCTAssertEqual(drains, index + 2)
        }
    }

    func assertDeploymentErrorsStayWithTheirWindow() throws {
        let h = try CLIDeployFixture(reconcile: { context in
            var result = BatchResult()
            let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
            for skill in (try? context.fetch(FetchDescriptor<Skill>())) ?? [] {
                for target in [.userWide] + projects.map(DeployTarget.project) {
                    result.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name,
                        platform: .claudeCode, target: BatchPairTarget(target),
                        error: "Reconcile failed for \(skill.directoryName)"))
                }
            }
            return result
        })
        let tab = DeployIntentModel(service: h.service), bulk = DeployIntentModel(service: h.service)
        XCTAssertEqual(h.handler.handle(h.request(), context: h.context).envelope.error?.code, "partial")
        XCTAssertNil(tab.error, "CLI failures belong only to the reply")
        XCTAssertNil(bulk.error)
        _ = try tab.set(true, skill: h.skill, platform: .claudeCode, target: .userWide, context: h.context)
        let tabError = try XCTUnwrap(tab.error)
        XCTAssertNil(bulk.error, "Another window must not display the tab's failure")
        _ = try BulkDeploySheet.perform(.deploy, forProject: true, platformVM: h.platform, intentModel: bulk,
            skills: [h.other], platforms: [.claudeCode], target: .project(h.project), machineIDs: [], context: h.context)
        XCTAssertNotNil(bulk.error)
        bulk.error = nil
        XCTAssertEqual(tab.error, tabError, "Dismissing the bulk alert must not dismiss the tab's alert")
        XCTAssertTrue(h.handler.handle(h.request(project: "Local"), context: h.context).envelope.ok)
        XCTAssertEqual(tab.error, tabError, "A successful CLI command must not clear a window's alert")
        bulk.reload(context: h.context)
        XCTAssertEqual(tab.error, tabError, "Refreshing another window must not clear this alert")
    }
}
