import Observation
import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryFlowCostTests: UpstreamHistoryCacheTestCase {
    func testManualCountObservationIgnoresWorkEventsButTracksManualChangesAndRemoval() async throws {
        let fixture = try sequenceFixture(.empty)
        let notifications = HistorySequenceCalls()
        withObservationTracking {
            _ = fixture.model.manualCheckCount(skillID: fixture.otherSkill.id)
        } onChange: { notifications.append("change") }
        fixture.enqueue("A")
        try await fixture.flow.drain()
        fixture.model.receive(.completed(UUID(), .persist), skillID: fixture.skill.id)
        XCTAssertEqual(notifications.values, [], "Hidden work and retired completions must not invalidate the manual count")
        fixture.model.invalidateForManualCheck(skillID: fixture.otherSkill.id)
        XCTAssertEqual(notifications.values, ["change"])
        XCTAssertEqual(fixture.model.manualCheckCount(skillID: fixture.otherSkill.id), 1)
        withObservationTracking {
            _ = fixture.model.manualCheckCount(skillID: fixture.otherSkill.id)
        } onChange: { notifications.append("remove") }
        fixture.model.remove(skillID: fixture.otherSkill.id)
        XCTAssertEqual(notifications.values, ["change", "remove"])
        XCTAssertEqual(fixture.model.manualCheckCount(skillID: fixture.otherSkill.id), 0)
        await fixture.flow.close()
    }

    func testLocalMeasurementAndPersistenceAreScheduledAtUtilityPriority() async throws {
        var scheduled: [String: TaskPriority] = [:]
        for seed in [UpstreamHistorySequenceFixture.Seed.empty, .memory] {
            let fixture = try sequenceFixture(seed)
            fixture.model.sequenceHooks?.scheduled = { kind, priority in scheduled[kind.rawValue] = priority }
            fixture.enqueue("A", changed: true)
            try await fixture.flow.drain()
            await fixture.flow.close()
        }
        XCTAssertEqual(scheduled, ["disk": .userInitiated, "read": .userInitiated, "probe": .userInitiated,
                                   "localEdits": .utility, "persist": .utility])
    }

    func testPersistenceDoesNotRepublishTheReadOutcome() async throws {
        let fixture = try sequenceFixture(.empty)
        let flow = fixture.flow
        fixture.enqueue("A")
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume",
                            "read1.start", "read1.finish", "read1.resume"])
        XCTAssertEqual(flow.publications.filter { $0.state == .loaded(fixture.fresh) }.count, 1)
        let notifications = HistorySequenceCalls()
        withObservationTracking { _ = fixture.model.state } onChange: { notifications.append("change") }
        try await flow.run(["persist1.start", "persist1.finish", "persist1.resume"])
        XCTAssertEqual(notifications.values, [])
        XCTAssertEqual(flow.publications.filter { $0.state == .loaded(fixture.fresh) }.count, 1)
        XCTAssertTrue(flow.finished)
        await flow.close()
    }

    func testDuplicatePublishDecisionsAreRecordedWithoutInvalidatingObservedState() throws {
        let fixture = try sequenceFixture(.memory)
        let notifications = HistorySequenceCalls()
        fixture.model.publish(.loaded(fixture.kept), skillID: fixture.skill.id)
        withObservationTracking { _ = fixture.model.state } onChange: { notifications.append("change") }
        fixture.model.publish(.loaded(fixture.kept), skillID: fixture.skill.id)
        XCTAssertEqual(fixture.flow.publications.count, 2, "Both real publication decisions must reach the seam")
        XCTAssertEqual(notifications.values, [], "An equal decision must not rerender the timeline")
    }

}
