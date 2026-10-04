import Foundation
import SwiftData
import XCTest
@testable import Pensieve

extension ScenarioHandoverLaunchTests {
    func testQuarantinedAndUnreadableLaunchesNeverRunOrCompleteHandover() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Pensieve/Services/ScenarioHandover.swift"),
                                encoding: .utf8)
        let unreachableFields = try NSRegularExpression(pattern: #"let\s+(?:storeUnreadable|quarantined)\s*:\s*Bool"#)
        XCTAssertNil(unreachableFields.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        for quarantine in [false, true] {
            let harness = try HandoverHarness(defaults: isolatedDefaults("excluded-\(quarantine)"))
            defer { try? harness.cleanUp() }
            try harness.seed()
            if quarantine {
                try GitService().initRepository(at: harness.root)
                try GitService().setRemote("file://" + harness.root + "/remote.git", at: harness.root)
            } else {
                try harness.files.writeFile(at: harness.root + "/manifest/manifest.yaml", content: "schema_version: 99\n")
            }
            let before = try harness.deployedFiles()
            let handover = RoundFourRecordingHandover(live: harness.handover())
            for _ in 0..<2 {
                let outcome = harness.launch(handover)
                XCTAssertEqual(outcome.quarantined, quarantine)
                XCTAssertEqual(outcome.rebuild.storeUnreadable, !quarantine)
                XCTAssertEqual(handover.calls, 0)
                XCTAssertFalse(harness.defaults.bool(forKey: ScenarioHandover.doneKey))
                XCTAssertNotNil(harness.defaults.object(forKey: ScenarioHandover.activeKey))
                XCTAssertEqual(try harness.freshContext().fetchCount(FetchDescriptor<ScenarioAssignment>()), 2)
                XCTAssertEqual(harness.manifest.writes, 0)
                XCTAssertEqual(try harness.deployedFiles(), before)
            }
            if quarantine { try GitService().removeRemote(at: harness.root) } else {
                try harness.files.writeFile(at: harness.root + "/manifest/manifest.yaml", content: "schema_version: 5\n")
            }
            XCTAssertFalse(harness.launch(handover).ingestionNeedsRetry)
            XCTAssertEqual(handover.calls, 1)
            try harness.assertComplete()
            XCTAssertEqual(try harness.deployedFiles(), before)
        }
    }
}

private final class RoundFourRecordingHandover: ScenarioHandingOver {
    let live: ScenarioHandingOver
    var calls = 0
    init(live: ScenarioHandingOver) { self.live = live }
    func handOver(context: ModelContext, readiness: ScenarioHandoverReadiness) throws {
        calls += 1
        try live.handOver(context: context, readiness: readiness)
    }
}
