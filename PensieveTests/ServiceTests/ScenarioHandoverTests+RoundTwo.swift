import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverTests {
    func testOnlyWorkingDeploysBecomeRealizedDuringHandover() throws {
        for kind in ["dangling", "wrong", "folder", "cursor-link", "cursor-foreign", "relative"] {
            let harness = try HandoverHarness(defaults: isolatedDefaults(kind))
            defer { try? harness.cleanUp() }
            let platform: PlatformTarget = kind.hasPrefix("cursor") ? .cursor : .codex
            let skill = try harness.seed(platforms: [platform])
            let path = harness.root + "/agents/" + platform.rawValue + "/skill"
            try harness.files.deleteFile(at: path)
            try installArtifact(kind, path: path, harness: harness)
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: platform.rawValue))
            try harness.context.save()
            let identity = harness.files.fileIdentity(at: path, followingLinks: false)
            try harness.handover().handOver(context: harness.freshContext(), readiness: .init())
            let context = harness.freshContext()
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0, kind)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), kind == "relative" ? 1 : 0, kind)
            XCTAssertEqual(harness.files.fileIdentity(at: path, followingLinks: false), identity, kind)
            XCTAssertTrue(try harness.manifest.read(fromRoot: harness.root).deployIntents.contains {
                $0.skillSlug == "skill" && $0.platformRaw == platform.rawValue && $0.projectKey == nil
            }, kind)
        }
    }

    func testMissingStoreFolderIsRetiredAsOrphanWithoutIntentOrSyncFailure() throws {
        let harness = try HandoverHarness(defaults: isolatedDefaults())
        defer { try? harness.cleanUp() }
        try harness.seed()
        try harness.files.deleteDirectory(at: harness.root + "/skills/skill")
        let before = try harness.deployedFiles()
        try harness.handover().handOver(context: harness.freshContext(), readiness: .init())
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
        for readiness in [ScenarioHandoverReadiness(manifestWritten: false),
                          ScenarioHandoverReadiness(rebuildSaveFailed: true),
                          ScenarioHandoverReadiness(ingestionNeedsRetry: true)] {
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
        case "folder": try harness.files.createDirectory(at: path)
        case "cursor-foreign": try harness.files.writeFile(at: path, content: "someone else's file")
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
