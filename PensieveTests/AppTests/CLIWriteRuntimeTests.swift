import Foundation
import Observation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class CLIWriteRuntimeTests: XCTestCase {
    func testBuiltDeployAndUndeployReachTheRuntimeAndWindowState() async throws {
        let h = try CLIDeployFixture()
        let paths = AppRuntimePaths(storeRoot: h.root, appSupportDir: h.directory.path)
        let runtime = try AppRuntime(container: h.context.container, platformVM: h.platform,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            launchReconcile: { _, _ in
                LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false, ingestedHeadStamp: "fixture")
            }, launchBackfill: { _ in }, hasRemoteConfigured: { false }, paths: paths, gitUsabilityProbe: { .usable })
        defer { runtime.commandServer?.stop() }
        runtime.start()
        await TestWait.until(failureMessage: "Runtime did not become ready") { runtime.commandsReady }
        let window = DeployIntentModel(service: runtime.deployMutations)
        let invalidations = Counter()
        withObservationTracking { _ = window.platformVM.deployIndex } onChange: { invalidations.increment() }
        let deployed = try await run("deploy", slug: h.skill.directoryName, appSupport: paths.appSupportDir)
        XCTAssertTrue(deployed.ok)
        XCTAssertEqual(deployed.changed, true)
        XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
        XCTAssertEqual(invalidations.value, 1, "The same presentation model observed by the window must invalidate")
        XCTAssertEqual(window.platformVM.deployIndex.records(for: h.skill.directoryName).count, 1)
        let context = runtime.container.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        let manifest = try NativeTestWork.run { try h.manifest.read(fromRoot: h.root) }
        XCTAssertEqual(manifest.deployIntents.first?.machineID, try runtime.machineObservability.identity.identifier())
        let removed = try await run("undeploy", slug: h.skill.directoryName, appSupport: paths.appSupportDir)
        XCTAssertTrue(removed.ok)
        XCTAssertEqual(removed.changed, true)
        XCTAssertFalse(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
        XCTAssertTrue(window.platformVM.deployIndex.records(for: h.skill.directoryName).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    private func run(_ command: String, slug: String, appSupport: String) async throws -> CLIEnvelope {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pensieve")
        process.arguments = [command, slug, "-a", "claude", "-g", "--json", "--app-support", appSupport]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = appSupport
        environment["HOME"] = appSupport
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let result = try await BlockingWork.run {
            try CLIProcessProbe.run(process, timeout: TestWait.hostedActionTimeoutSeconds)
        }
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        let diagnostics = try errors.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0, String(bytes: bytes + diagnostics, encoding: .utf8) ?? "Unreadable CLI output")
        return try JSONDecoder().decode(CLIEnvelope.self, from: bytes)
    }
}
