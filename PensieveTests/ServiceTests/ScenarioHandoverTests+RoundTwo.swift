import Darwin
import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    func testOnlyWorkingDeploysBecomeRealizedDuringHandover() throws {
        for kind in ["accepted", "dangling", "wrong", "folder", "file", "relative",
                     "cursor-link", "cursor-foreign", "cursor-stale", "cursor-current", "cursor-folder", "fifo"] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(kind))
            defer { try? harness.cleanUp() }
            let platform: PlatformTarget = kind.hasPrefix("cursor") ? .cursor : .codex
            let skill = try harness.seed(platforms: [platform])
            let path = harness.root + "/agents/" + platform.rawValue + "/skill"
            try harness.files.deleteFile(at: path)
            try installArtifact(kind, path: path, harness: harness)
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: platform.rawValue))
            try harness.context.save()
            let before = try harness.deployedFiles()
            XCTAssertFalse(harness.launch().ingestionNeedsRetry)
            let context = harness.freshContext()
            let managed = ["accepted", "cursor-foreign", "cursor-stale", "cursor-current"].contains(kind)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0, kind)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), managed ? 1 : 0, kind)
            XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).deployIntents.contains {
                $0.skillSlug == "skill" && $0.platformRaw == platform.rawValue && $0.projectKey == nil
            }, managed, kind)
            let deployments = HandoverDeployments(root: harness.root)
            let reconciler = IntentReconciler(platformVM: deployments.platformVM, machineIdentity: harness.identity,
                                             handoverIsComplete: { true })
            for _ in 0..<2 { XCTAssertFalse(reconciler.reconcile(context: context).hasFailures, kind) }
            XCTAssertEqual(deployments.createCalls, 0, kind)
            XCTAssertEqual(deployments.removeCalls, 0, kind)
            XCTAssertEqual(try harness.deployedFiles(), before, kind)
            if !managed {
                XCTAssertTrue(harness.logs.contains { $0.contains("Left unmanaged:") && $0.contains(platform.rawValue) }, kind)
                XCTAssertTrue(harness.logs.contains { $0.contains("1 left unmanaged") }, kind)
            }
        }
    }

    func testMissingStoreFolderIsRetiredAsOrphanWithoutIntentOrSyncFailure() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        try harness.files.deleteDirectory(at: harness.root + "/skills/skill")
        let before = try harness.deployedFiles()
        try harness.handover().handOver(context: harness.freshContext(), readiness: ScenarioHandoverReadiness(
                manifestWritten: true, rebuildSaveFailed: false,
                ingestionNeedsRetry: false, storeUnreadable: false, quarantined: false))
        let context = harness.freshContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertEqual(try harness.manifest.read(fromRoot: harness.root).deployIntents,
                       harness.unrelated.sorted { $0.machineID < $1.machineID })
        XCTAssertEqual(harness.manifest.writes, 0)
        XCTAssertTrue(harness.logs.contains { $0.contains("no safe store folder") && $0.contains("skill") })
        let deploys = HandoverDeployments(root: harness.root)
        let reconciler = IntentReconciler(platformVM: deploys.platformVM, machineIdentity: harness.identity,
                                         handoverIsComplete: { true })
        for _ in 0..<2 { XCTAssertFalse(reconciler.reconcile(context: context).hasFailures) }
        XCTAssertEqual(deploys.createCalls, 0)
        XCTAssertEqual(try harness.deployedFiles(), before)
    }

    func testConcreteHandoverRequiresExplicitReadinessAndHonorsEveryGate() throws {
        // This API requirement is structural: a default silently bypasses every gate for direct callers.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Pensieve/Services/ScenarioHandover.swift"),
                                encoding: .utf8)
        let defaulted = try NSRegularExpression(pattern: #"readiness:\s*ScenarioHandoverReadiness\s*="#)
        XCTAssertNil(defaulted.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        let defaults = try NSRegularExpression(pattern:
            #"(?:var|let)\s+(?:manifestWritten|rebuildSaveFailed|ingestionNeedsRetry|storeUnreadable|quarantined)"#
                + #"(?:\s*:\s*Bool)?\s*="#
        )
        XCTAssertNil(defaults.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        for gate in 0..<5 {
            let readiness = ScenarioHandoverReadiness(manifestWritten: gate != 0, rebuildSaveFailed: gate == 1,
                ingestionNeedsRetry: gate == 2, storeUnreadable: gate == 3, quarantined: gate == 4)
            let harness = try HandoverHarness(defaults: isolatedDefaults())
            defer { try? harness.cleanUp() }
            try harness.seed()
            let before = try harness.deployedFiles()
            try harness.handover().handOver(context: harness.freshContext(), readiness: readiness)
            XCTAssertEqual(harness.identity.calls, 0)
            XCTAssertEqual(harness.manifest.writes, 0)
            XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
            XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
            XCTAssertEqual(try harness.deployedFiles(), before)
        }
    }

    private func installArtifact(_ kind: String, path: String, harness: HandoverHarness) throws {
        switch kind {
        case "folder", "cursor-folder": try harness.files.createDirectory(at: path)
        case "accepted": try harness.files.createSymlink(at: path, pointingTo: harness.root + "/skills/skill")
        case "fifo": XCTAssertEqual(mkfifo(path, 0o600), 0)
        case "file", "cursor-foreign", "cursor-stale": try harness.files.writeFile(at: path, content: "someone else's file")
        case "cursor-current": try harness.files.writeFile(at: path, content: "compiled bytes")
        case "relative": try harness.files.createSymlink(at: path, pointingTo: "../../skills/skill")
        default:
            let target = harness.root + "/" + (kind == "dangling" ? "absent" : "other")
            if kind != "dangling" {
                if kind == "cursor-link" { try harness.files.writeFile(at: target, content: "compiled bytes") } else {
                    try harness.files.createDirectory(at: target)
                }
            }
            try harness.files.createSymlink(at: path, pointingTo: target)
        }
    }
}
