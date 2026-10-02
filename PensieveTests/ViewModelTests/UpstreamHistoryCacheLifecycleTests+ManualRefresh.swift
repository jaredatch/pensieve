import XCTest
@testable import Pensieve

@MainActor
extension UpstreamHistoryCacheLifecycleTests {
    /// Protects 39.2-d: Check for Updates cannot replace a first-read failure or swallow its Try Again.
    func testManualCheckTreatsHeldFirstReadFailureAsTryAgain() async {
        enum Failure: LocalizedError {
            case offline
            var errorDescription: String? { "The repository couldn't be reached." }
        }
        let skill = installedHistorySkill()
        let replacement = result(head: String(repeating: "2", count: 40), subject: "replacement")
        let probe = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in
            probe.recordCall()
            if probe.calls == 1 { throw Failure.offline }
            return replacement
        }
        await model.request(skill: skill)
        model.invalidateForManualCheck(skillID: skill.id)
        await model.request(skill: skill, intent: .retry)

        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(model.state, .loaded(replacement))
        await model.request(skill: skill, intent: .mountedRefresh)
        XCTAssertEqual(probe.calls, 2)
    }

    /// Protects 39.2-g: after Check for Updates finds nothing kept, the next History open loads normally.
    func testFirstOpenAfterManualCheckWithNothingKeptLoads() async {
        let skill = installedHistorySkill()
        let loaded = result(head: String(repeating: "2", count: 40), subject: "loaded")
        let probe = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in probe.recordCall(); return loaded }

        model.invalidateForManualCheck(skillID: skill.id)

        XCTAssertEqual(probe.calls, 0)
        XCTAssertNotEqual(model.state, .loading)
        await model.request(skill: skill)
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(model.state, .loaded(loaded))
    }

    /// Protects 39.2-f: an appearance consumes a hidden manual ask only by starting its refresh.
    func testFirstOpenAfterHiddenManualCheckRefreshesAHeldFailure() async {
        enum Failure: LocalizedError {
            case offline
            var errorDescription: String? { "The repository couldn't be reached." }
        }
        let old = result(head: String(repeating: "1", count: 40), subject: "old")
        let refreshed = result(head: String(repeating: "2", count: 40), subject: "refreshed")
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        let reads = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in
            reads.recordCall()
            if reads.calls == 2 { throw Failure.offline }
            return reads.calls == 1 ? old : refreshed
        }

        await model.request(skill: skill)
        await model.request(skill: skill, intent: .retry)
        XCTAssertEqual(
            model.state,
            .loadedWithFailure(old, "History couldn't be refreshed. The repository couldn't be reached.")
        )

        model.invalidateForManualCheck(skillID: skill.id)
        await model.request(skill: skill, intent: .appearance)

        XCTAssertEqual(reads.calls, 3)
        XCTAssertEqual(model.state, .loaded(refreshed))
    }

    /// Protects 39.2-b and 39.2-d: reopening kept rows preserves their failure note without a fetch.
    func testReopeningHeldRefreshFailureKeepsTheNoteWithoutFetching() async {
        enum Failure: LocalizedError {
            case offline
            var errorDescription: String? { "The repository couldn't be reached." }
        }
        let old = result(head: String(repeating: "1", count: 40), subject: "old")
        let skill = installedHistorySkill(recordedHead: old.headCommit)
        let reads = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in
            reads.recordCall()
            if reads.calls == 2 { throw Failure.offline }
            return old
        }

        await model.request(skill: skill)
        await model.request(skill: skill, intent: .retry)
        let failureState = UpstreamHistoryLoadState.loadedWithFailure(
            old,
            "History couldn't be refreshed. The repository couldn't be reached."
        )
        XCTAssertEqual(model.state, failureState)

        await model.request(skill: skill, intent: .appearance)

        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(model.state, failureState)
    }

    /// Protects 39.2-c and 39.2-d: a success retires older failures for questions it supersedes.
    func testSuccessfulRefreshRetiresAnOlderHeadsFailureBeforeThatHeadReturns() async {
        enum Failure: LocalizedError {
            case offline
            var errorDescription: String? { "The repository couldn't be reached." }
        }
        let firstHead = String(repeating: "1", count: 40)
        let secondHead = String(repeating: "2", count: 40)
        let first = result(head: firstHead, subject: "first")
        let second = result(head: secondHead, subject: "second")
        let returned = result(head: firstHead, subject: "returned")
        let skill = installedHistorySkill(recordedHead: firstHead)
        let reads = LockedHistoryProbe()
        let model = owner(cache: cache()) { _, _, _ in
            reads.recordCall()
            switch reads.calls {
            case 1: return first
            case 2: throw Failure.offline
            case 3: return second
            default: return returned
            }
        }

        await model.request(skill: skill)
        await model.request(skill: skill, intent: .retry)
        skill.lastCheckedHead = secondHead
        await model.request(skill: skill, intent: .mountedRefresh)
        skill.lastCheckedHead = firstHead
        await model.request(skill: skill, intent: .mountedRefresh)

        XCTAssertEqual(reads.calls, 4)
        XCTAssertEqual(model.state, .loaded(returned))
    }
}
