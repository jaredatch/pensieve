import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class InstalledSkillHistoryFlowLifetimeTests: UpstreamHistoryCacheTestCase {
    func testClosingTabKeepsOwnedWorkAndReopeningJoinsOrShowsItsOutcome() async throws {
        try await exercise(closesWindow: false)
    }

    func testClosingWindowKeepsOwnedWorkAndReopeningJoinsOrShowsItsOutcome() async throws {
        try await exercise(closesWindow: true)
    }

    private func exercise(closesWindow: Bool) async throws {
        for kind in [UpstreamHistorySequenceHooks.Work.read, .probe, .localEdits, .persist] {
            for reopenBeforeFinish in [true, false] {
                for fails in kind == .read || kind == .probe ? [false, true] : [false] {
                    let fixture = try lifetimeFixture(kind: kind, fails: fails)
                    try await check(fixture, closesWindow: closesWindow, reopenBeforeFinish: reopenBeforeFinish)
                }
            }
        }
    }

    private func check(_ fixture: HistoryLifetimeFixture, closesWindow: Bool, reopenBeforeFinish: Bool) async throws {
        let host = HistoryLifetimeHostState()
        if fixture.kind == .localEdits {
            host.revision = UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0)
        }
        var window = fixture.makeWindow(host: host)
        defer { fixture.gate.release(); window.close() }
        await TestWait.until(failureMessage: "Hosted \(fixture.kind) did not reach its hold") { fixture.gate.held != nil }
        if closesWindow {
            window.close()
            XCTAssertFalse(window.isVisible, "The hosted NSWindow must actually close")
        } else {
            host.visible = false
            await TestWait.until(failureMessage: "The History tab did not disappear") { host.disappeared }
        }
        let requestsAtClose = fixture.gate.requests
        if reopenBeforeFinish {
            if closesWindow { window = fixture.makeWindow(host: host) } else { host.visible = true }
            await TestWait.until(failureMessage: "Reopening never requested History") {
                fixture.gate.requests > requestsAtClose
            }
            XCTAssertNotNil(fixture.gate.held, "Reopening must not release owned work")
        }
        fixture.gate.release()
        await TestWait.until(failureMessage: "Owned work did not finish after close") {
            fixture.model.flows[fixture.skill.id]?.jobs.isEmpty == true
        }
        let outcome = fixture.model.state
        try fixture.assertOutcome()
        if !reopenBeforeFinish {
            if closesWindow { window = fixture.makeWindow(host: host) } else { host.visible = true }
            await TestWait.until(failureMessage: "Reopening after completion never requested History") {
                fixture.gate.requests > requestsAtClose
            }
            await TestWait.until(failureMessage: "Reopened History never settled") {
                fixture.model.flows[fixture.skill.id]?.jobs.isEmpty == true
            }
            XCTAssertEqual(fixture.model.state, outcome)
        }
        fixture.assertCalls(reopenedAfterFailure: !reopenBeforeFinish && fixture.kind == .read && fixture.fails)
    }

    private func lifetimeFixture(kind: UpstreamHistorySequenceHooks.Work, fails: Bool) throws -> HistoryLifetimeFixture {
        let skill = installedHistorySkill(recordedHead: String(repeating: "1", count: 40))
        let kept = result(head: String(repeating: "1", count: 40), subject: "kept")
        let fresh = result(head: String(repeating: "2", count: 40), subject: "fresh")
        let gate = HistoryLifetimeGate(kind: kind)
        let calls = HistorySequenceCalls()
        let disk = UpstreamHistoryCache(directory: cacheDirectory + "/" + UUID().uuidString, fileService: fileService)
        let model = historyOwner(read: { _, _, _ in
            calls.append("read")
            if fails { throw HistoryLifetimeFailure.offline }
            return fresh
        }, head: { _ in
            calls.append("probe")
            if fails { throw HistoryLifetimeFailure.offline }
            return fresh.headCommit
        }, localEdits: { _, _, _ in calls.append("edits"); return .countsUnknown }, cache: disk,
                                 onRequest: { _ in gate.requests += 1 })
        if kind == .probe || kind == .localEdits {
            try seedHistoryMemory(kept, for: skill, in: model)
            try seedHistoryDisk(kept, for: skill, in: disk)
            if kind == .localEdits { model.flows[skill.id]?.probeSpent = true }
        }
        model.sequenceHooks = gate.hooks
        return HistoryLifetimeFixture(model: model, skill: skill, disk: disk, gate: gate,
                                      calls: calls, kind: kind, fails: fails, kept: kept, fresh: fresh)
    }
}

private enum HistoryLifetimeFailure: LocalizedError {
    case offline
    var errorDescription: String? { "lifetime offline" }
}

@MainActor
@Observable
final class HistoryLifetimeHostState {
    var visible = true
    var disappeared = false
    var revision = UpstreamHistoryLocalRevision.initial
}

struct HistoryLifetimeHost: View {
    let skill: Skill
    let history: UpstreamHistoryViewModel
    @Bindable var host: HistoryLifetimeHostState

    var body: some View {
        if host.visible, let origin = skill.installedOrigin {
            InstalledSkillHistoryView(skill: skill, currentBody: "# Current", origin: origin,
                                      updateAvailable: false, localRevision: host.revision,
                                      onOpenUpdates: {}, onUpdateCheck: { _ in }, history: history)
                .onDisappear { host.disappeared = true }
        }
    }
}

@MainActor
final class HistoryLifetimeGate {
    let kind: UpstreamHistorySequenceHooks.Work
    var heldIDs: Set<UUID> = []
    var held: CheckedContinuation<Void, Never>?
    var released = false
    var requests = 0

    init(kind: UpstreamHistorySequenceHooks.Work) { self.kind = kind }

    var hooks: UpstreamHistorySequenceHooks {
        UpstreamHistorySequenceHooks(
            started: { [self] work, id in if work == kind { heldIDs.insert(id) } },
            enter: { [self] id in
                if heldIDs.contains(id), !released { await withCheckedContinuation { held = $0 } }
            },
            finish: { _ in }, waiting: { _ in }, resume: { _ in }, published: { _, _ in }
        )
    }

    func release() {
        released = true
        let continuation = held
        held = nil
        continuation?.resume()
    }
}
