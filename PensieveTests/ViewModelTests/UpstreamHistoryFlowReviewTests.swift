import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryFlowReviewTests: UpstreamHistoryCacheTestCase {
    func testHiddenManualAskSurvivesAppearanceJoiningAnOlderRefresh() async throws {
        for intent in [UpstreamHistoryViewModel.RequestIntent.appearance, .mountedRefresh, .retry] {
            let fixture = try sequenceFixture(.memory)
            let flow = fixture.flow
            fixture.enqueue("A", intent: .retry)
            try await flow.run(["A.request", "read1.start"])
            fixture.model.invalidateForManualCheck(skillID: fixture.skill.id)
            fixture.enqueue("B", intent: intent)
            try await flow.release("B.request")
            XCTAssertTrue(fixture.model.flows[fixture.skill.id]?.manualPending == true)
            try await flow.drain()
            XCTAssertEqual(fixture.calls.values, ["read", "read"])
            XCTAssertFalse(fixture.model.flows[fixture.skill.id]?.manualPending == true)
            fixture.enqueue("C")
            try await flow.drain()
            XCTAssertEqual(fixture.calls.values, ["read", "read"], "The separate hidden ask must still own a refresh")
            await flow.close()
        }
    }

    func testReplacedLocalMeasurementContinuesWithTheNewHeldHead() async throws {
        let skill = installedHistorySkill(recordedHead: String(repeating: "1", count: 40))
        let old = result(head: String(repeating: "1", count: 40))
        let fresh = result(head: String(repeating: "2", count: 40), window: 2)
        let measurements = HistorySequenceCalls()
        var checks: [UUID] = []
        let model = owner(cache: cache(), read: { _, _, _ in fresh }, localEdits: { _, _, _ in
            measurements.append("measure")
            return .countsUnknown
        })
        try seedHistoryMemory(old, for: skill, in: model)
        let flow = UpstreamHistorySequenceHarness()
        model.sequenceHooks = flow.hooks
        flow.enqueue("A") { await model.request(skill: skill, windowCount: 2) }
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume", "read1.start"])
        flow.enqueue("C") {
            await model.request(skill: skill, localRevision: .init(appWriteRevision: 1, watcherEventSequence: 0),
                                onUpdateCheck: { checks.append($0) })
        }
        try await flow.run(["C.request", "localEdits1.start", "read1.finish", "read1.resume",
                            "localEdits1.finish", "localEdits1.resume"])
        try await flow.drain()
        XCTAssertEqual(model.state, .loaded(fresh.replacing(localEdits: .countsUnknown)))
        XCTAssertEqual(measurements.values, ["measure", "measure"])
        XCTAssertEqual(checks, [skill.id])
        await flow.close()
    }

    func testWiderWindowGoesFromDiskMissToReadWithoutFinalizingNarrowRows() async throws {
        let skill = installedHistorySkill(recordedHead: String(repeating: "1", count: 40))
        let old = result(head: String(repeating: "1", count: 40))
        let wide = result(head: old.headCommit, window: 2)
        let model = owner(cache: cache(), read: { _, _, _ in wide })
        try seedHistoryMemory(old, for: skill, in: model)
        let flow = UpstreamHistorySequenceHarness()
        model.sequenceHooks = flow.hooks
        flow.enqueue("A") {
            await model.request(skill: skill, windowCount: 2,
                                localRevision: .init(appWriteRevision: 1, watcherEventSequence: 0))
        }
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume"])
        XCTAssertEqual(model.state, .refreshing(old))
        XCTAssertEqual(flow.enabled, ["read1.start"])
        XCTAssertFalse(flow.publications.contains { $0.state == .loaded(old) })
        try await flow.drain()
        XCTAssertEqual(model.state, .loaded(wide))
        XCTAssertEqual(flow.work.values.filter { $0.kind == .localEdits }.count, 0)
        await flow.close()
    }

    func testAnyAnsweringHeldWindowKeepsAnInflightPersistsGeneration() async throws {
        let headX = String(repeating: "1", count: 40)
        let headY = String(repeating: "3", count: 40)
        let readHead = String(repeating: "2", count: 40)
        let skill = installedHistorySkill(recordedHead: headX)
        let wide = result(head: readHead, window: 2)
        let narrow = result(head: readHead)
        let disk = cache()
        let model = owner(cache: disk, read: { _, _, window in window == 2 ? wide : narrow })
        let flow = UpstreamHistorySequenceHarness()
        model.sequenceHooks = flow.hooks
        flow.enqueue("A") { await model.request(skill: skill, windowCount: 2) }
        try await flow.run(["A.request", "disk1.start", "disk1.finish", "disk1.resume",
                            "read1.start", "read1.finish", "read1.resume"])
        let generation = disk.beginRequest(skillID: skill.id, superseding: false)
        skill.lastCheckedHead = headY
        try seedHistoryMemory(narrow, for: skill, in: model)
        XCTAssertEqual(model.held.count, 2)
        flow.enqueue("B") { await model.request(skill: skill) }
        try await flow.release("B.request")
        XCTAssertEqual(disk.beginRequest(skillID: skill.id, superseding: false), generation)
        try await flow.run(["persist1.start", "persist1.finish", "persist1.resume"])
        let saved = disk.load(skillID: skill.id, origin: try origin(for: skill), minimumWindow: 2,
                              generation: disk.beginRequest(skillID: skill.id, superseding: false))
        XCTAssertEqual(saved?.result, wide, "The valid old persist must not be fenced by selecting only the widest answer")
        try await flow.drain()
        await flow.close()
    }

    func testCompatibleJoinKeepsTheAskUntilANewReadStarts() async throws {
        for window in [1, 2] {
            let skill = installedHistorySkill(recordedHead: String(repeating: "1", count: 40))
            let old = result(head: String(repeating: "1", count: 40))
            let fresh = result(head: String(repeating: "2", count: 40), window: window)
            let calls = HistorySequenceCalls()
            let model = owner(cache: cache(), read: { _, _, _ in calls.append("read"); return fresh })
            try seedHistoryMemory(old, for: skill, in: model)
            let flow = UpstreamHistorySequenceHarness()
            model.sequenceHooks = flow.hooks
            flow.enqueue("A") { await model.request(skill: skill, windowCount: window, intent: .retry) }
            try await flow.release("A.request")
            if window == 2 { try await flow.run(["disk1.start", "disk1.finish", "disk1.resume"]) }
            try await flow.release("read1.start")
            model.invalidateForManualCheck(skillID: skill.id)
            skill.lastCheckedHead = fresh.headCommit
            flow.enqueue("B") { await model.request(skill: skill, windowCount: window) }
            try await flow.release("B.request")
            if window == 2 { try await flow.run(["disk2.start", "disk2.finish", "disk2.resume"]) }
            XCTAssertTrue(model.flows[skill.id]?.manualPending == true, "A compatible join predates the ask")
            try await flow.drain()
            XCTAssertEqual(calls.values, ["read", "read"])
            XCTAssertFalse(model.flows[skill.id]?.manualPending == true)
            await flow.close()
        }
    }

    func testVisibleCheckReaskedAsAppearanceAfterRehostingRunsItsOwnRead() async throws {
        let fixture = try sequenceFixture(.memory)
        fixture.enqueue("A", intent: .retry)
        try await fixture.flow.run(["A.request", "read1.start"])
        fixture.model.invalidateForManualCheck(skillID: fixture.skill.id)
        // A newly hosted History view has no prior manual count and sends appearance.
        fixture.enqueue("rehost", intent: .appearance)
        try await fixture.flow.release("rehost.request")
        XCTAssertEqual(fixture.model.state, .refreshing(fixture.kept))
        try await fixture.flow.run(["read1.finish", "read1.resume"])
        XCTAssertEqual(fixture.model.state, .refreshing(fixture.fresh))
        try await fixture.flow.drain()
        XCTAssertEqual(fixture.calls.values, ["read", "read"])
        XCTAssertFalse(fixture.model.flows[fixture.skill.id]?.manualPending == true)
        await fixture.flow.close()
    }

    func testMeasurementFollowsTheSameReadHeadAcrossHeldKeys() async throws {
        for wider in [false, true] {
            let fixture = try sequenceFixture(.memory, edits: .countsUnknown)
            fixture.enqueue("A", changed: true)
            try await fixture.flow.run(["A.request", "localEdits1.start"])
            if !wider { fixture.skill.lastCheckedHead = String(repeating: "3", count: 40) }
            let replacement = result(head: fixture.kept.headCommit, window: wider ? 2 : 1)
            try seedHistoryMemory(replacement, for: fixture.skill, in: fixture.model)
            try await fixture.flow.drain()
            XCTAssertEqual(fixture.flow.work.values.filter { $0.kind == .localEdits }.count, 1)
            XCTAssertEqual(fixture.model.state, .loaded(replacement.replacing(localEdits: .countsUnknown)))
            await fixture.flow.close()
        }
    }

    func testNarrowAnswerCertifiesWiderRowsAtTheSameReadHead() async throws {
        let fixture = try sequenceFixture(.memory)
        let wide = result(head: fixture.fresh.headCommit, window: 2)
        try seedHistoryMemory(wide, for: fixture.skill, in: fixture.model)
        fixture.skill.lastCheckedHead = String(repeating: "3", count: 40)
        try seedHistoryMemory(fixture.fresh, for: fixture.skill, in: fixture.model)
        fixture.model.flows[fixture.skill.id]?.probeSpent = true
        fixture.flow.enqueue("A") { await fixture.model.request(skill: fixture.skill, windowCount: 2) }
        try await fixture.flow.release("A.request")
        XCTAssertEqual(fixture.model.state, .loaded(wide))
        XCTAssertEqual(fixture.flow.work.values.filter { $0.kind == .read }.count, 0)
        fixture.model.remove(skillID: fixture.skill.id)
        try await fixture.flow.drain()
        await fixture.flow.close()
    }

    func testDifferentHeadFollowupWaitsForTheJoinedReadsPersist() async throws {
        let fixture = try sequenceFixture(.memory)
        fixture.enqueue("A", intent: .retry)
        try await fixture.flow.run(["A.request", "read1.start"])
        fixture.skill.lastCheckedHead = String(repeating: "3", count: 40)
        fixture.enqueue("B", intent: .mountedRefresh)
        try await fixture.flow.run(["B.request", "read1.finish", "read1.resume"])
        XCTAssertEqual(fixture.flow.enabled, ["persist1.start"], "The original question must be durable before the follow-up")
        try await fixture.flow.run(["persist1.start", "persist1.finish", "persist1.resume"])
        XCTAssertEqual(fixture.flow.enabled, ["read2.start"])
        try await fixture.flow.drain()
        XCTAssertEqual(fixture.calls.values, ["read", "read"])
        await fixture.flow.close()
    }

    func testHiddenCheckDuringProbeIsSpentOnlyByAMovedHeadsRead() async throws {
        for (moved, fails) in [(false, false), (true, false), (false, true)] {
            let fixture = try sequenceFixture(.memory, moved: moved, fails: fails)
            fixture.enqueue("A")
            try await fixture.flow.run(["A.request", "probe1.start"])
            fixture.model.invalidateForManualCheck(skillID: fixture.skill.id)
            try await fixture.flow.run(["probe1.finish", "probe1.resume"])
            try await fixture.flow.drain()
            XCTAssertEqual(fixture.calls.values, moved ? ["probe", "read"] : ["probe"])
            XCTAssertEqual(fixture.model.flows[fixture.skill.id]?.manualPending, !moved)
            await fixture.flow.close()
        }
    }

}
