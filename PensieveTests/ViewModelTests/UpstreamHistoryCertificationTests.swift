import XCTest
@testable import Pensieve

@MainActor
final class UpstreamHistoryCertificationTests: UpstreamHistoryCacheTestCase {
    func testWiderAwayCompletionKeepsTheNarrowQuestionsCertification() async throws {
        for window in [1, 2] {
            let fixture = try sequenceFixture(.memory)
            let skill = fixture.skill
            let flow = fixture.flow
            let wide = result(head: fixture.fresh.headCommit, window: 2)
            let calls = HistorySequenceCalls()
            let owner = owner(cache: fixture.disk, read: { _, _, count in
                calls.append("w\(count)")
                return count == 2 ? wide : fixture.fresh
            })
            try seedHistoryMemory(fixture.kept, for: skill, in: owner)
            try seedHistoryMemory(fixture.otherResult, for: fixture.otherSkill, in: owner)
            owner.flows[fixture.otherSkill.id]?.probeSpent = true
            owner.sequenceHooks = flow.hooks
            flow.enqueue("R") { await owner.request(skill: skill, windowCount: 2, intent: .retry) }
            try await flow.run(["R.request", "disk1.start", "disk1.finish", "disk1.resume", "read1.start"])
            flow.enqueue("away") { await owner.request(skill: fixture.otherSkill) }
            try await flow.release("away.request")
            skill.lastCheckedHead = String(repeating: "3", count: 40)
            flow.enqueue("C") { await owner.request(skill: skill) }
            try await flow.run(["C.request", "read2.start", "read2.finish", "read2.resume",
                                "read1.finish", "read1.resume"])
            try await flow.drain()
            flow.enqueue("back") { await owner.request(skill: skill, windowCount: window, intent: .mountedRefresh) }
            try await flow.drain()
            XCTAssertEqual(calls.values, ["w2", "w1"], "A wider same-head completion must preserve Y’s answer")
            XCTAssertEqual(owner.state, .loaded(wide))
            await flow.close()
        }
    }

    func testShowOlderKeepsTheWidestCertifiedRowsUntilItsRead() async throws {
        let fixture = try sequenceFixture(.memory)
        let wide = result(head: fixture.fresh.headCommit, window: 2)
        let older = result(head: fixture.fresh.headCommit, window: 3)
        let model = owner(cache: fixture.disk, read: { _, _, _ in older })
        try seedHistoryMemory(wide, for: fixture.skill, in: model)
        fixture.skill.lastCheckedHead = String(repeating: "3", count: 40)
        try seedHistoryMemory(fixture.fresh, for: fixture.skill, in: model)
        model.flows[fixture.skill.id]?.probeSpent = true
        model.sequenceHooks = fixture.flow.hooks
        fixture.flow.enqueue("open") { await model.request(skill: fixture.skill, windowCount: 2) }
        try await fixture.flow.release("open.request")
        XCTAssertEqual(model.state, .loaded(wide))
        fixture.flow.enqueue("older") { await model.request(skill: fixture.skill, windowCount: 3) }
        try await fixture.flow.release("older.request")
        XCTAssertEqual(model.state, .refreshing(wide))
        try await fixture.flow.run(["disk1.start", "disk1.finish", "disk1.resume"])
        XCTAssertEqual(model.state, .refreshing(wide))
        try await fixture.flow.drain()
        XCTAssertEqual(model.state, .loaded(older))
        await fixture.flow.close()
    }

    func testCompatibleCompletionPublishesTheCertifiedAnswerBeforePersistence() async throws {
        let fixture = try sequenceFixture(.memory)
        let wide = result(head: fixture.fresh.headCommit, window: 2)
        let model = owner(cache: fixture.disk, read: { _, _, count in count == 2 ? wide : fixture.fresh })
        try seedHistoryMemory(fixture.kept, for: fixture.skill, in: model)
        let flow = fixture.flow
        model.sequenceHooks = flow.hooks
        flow.enqueue("R") { await model.request(skill: fixture.skill, intent: .retry) }
        try await flow.run(["R.request", "read1.start"])
        fixture.skill.lastCheckedHead = String(repeating: "3", count: 40)
        flow.enqueue("C") { await model.request(skill: fixture.skill, windowCount: 2) }
        try await flow.run(["C.request", "disk1.start", "disk1.finish", "disk1.resume", "read2.start"])
        flow.enqueue("B") { await model.request(skill: fixture.skill) }
        try await flow.run(["B.request", "read2.finish", "read2.resume", "read1.finish", "read1.resume"])
        XCTAssertEqual(model.state, .loaded(wide), "Certified rows must not wait for persistence to stop Updating")
        XCTAssertEqual(flow.publications.filter { $0.event == "read1.resume" }.count, 1)
        // Read 2 completed first, so persist2 belongs to the joined read 1.
        try await flow.run(["persist2.start", "persist2.finish", "persist2.resume"])
        XCTAssertFalse(flow.publications.contains { $0.event == "persist2.resume" })
        try await flow.drain()
        await flow.close()
    }

    func testPersistAdvancesTheWaiterWhenAnotherReadSuppliesItsAnswer() async throws {
        try await runReadPersistRace(answeredAtRead: false)
    }

    func testPersistDoesNotAdvanceAgainAfterAnotherReadEvictsTheAnswer() async throws {
        try await runReadPersistRace(answeredAtRead: true)
    }

    private func runReadPersistRace(answeredAtRead: Bool) async throws {
        let fixture = try sequenceFixture(.memory)
        let question = String(repeating: "3", count: 40)
        let otherQuestion = String(repeating: "4", count: 40)
        let first = answeredAtRead ? result(head: question) : fixture.fresh
        let wide = result(head: answeredAtRead ? String(repeating: "5", count: 40) : first.headCommit, window: 2)
        let calls = HistorySequenceCalls()
        let model = owner(cache: fixture.disk, read: { _, _, count in
            calls.append("w\(count)")
            return count == 1 ? first : wide
        })
        try seedHistoryMemory(fixture.kept, for: fixture.skill, in: model)
        let flow = fixture.flow
        model.sequenceHooks = flow.hooks
        flow.enqueue("R") { await model.request(skill: fixture.skill, intent: .retry) }
        try await flow.run(["R.request", "read1.start"])
        fixture.skill.lastCheckedHead = answeredAtRead ? otherQuestion : question
        flow.enqueue("C") { await model.request(skill: fixture.skill, windowCount: 2) }
        try await flow.run(["C.request", "disk1.start", "disk1.finish", "disk1.resume", "read2.start"])
        fixture.skill.lastCheckedHead = question
        flow.enqueue("B") { await model.request(skill: fixture.skill) }
        try await flow.run(["B.request", "read1.finish", "read1.resume"])
        XCTAssertEqual(model.state, answeredAtRead ? .loaded(first) : .refreshing(fixture.kept))
        XCTAssertNotEqual(flow.lanes["B"], .done, "The current compatible waiter still owns the persist wait")
        try await flow.run(["read2.finish", "read2.resume", "persist1.start", "persist1.finish", "persist1.resume"])
        XCTAssertEqual(model.state, .loaded(answeredAtRead ? first : wide))
        XCTAssertEqual(flow.publications.filter { $0.event == "persist1.resume" }.count, answeredAtRead ? 0 : 1)
        try await flow.drain()
        XCTAssertEqual(calls.values, ["w1", "w2"], "Persistence must not make a second read decision")
        XCTAssertEqual(model.state, .loaded(answeredAtRead ? first : wide))
        XCTAssertEqual(flow.lanes["B"], .done)
        XCTAssertTrue(flow.finished)
        XCTAssertTrue(model.flows[fixture.skill.id]?.jobs.isEmpty == true)
        await flow.close()
    }
}
