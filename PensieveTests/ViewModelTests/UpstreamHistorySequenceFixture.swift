import XCTest
@testable import Pensieve

@MainActor
struct UpstreamHistorySequenceFixture {
    enum Seed: String, CaseIterable {
        case empty, disk, memory
    }
    let flow: UpstreamHistorySequenceHarness
    let model: UpstreamHistoryViewModel
    let skill: Skill
    let otherSkill: Skill
    let otherResult: UpstreamHistoryResult
    let disk: UpstreamHistoryCache
    let calls: HistorySequenceCalls
    let kept: UpstreamHistoryResult
    let fresh: UpstreamHistoryResult

    func enqueue(
        _ label: String,
        after: String? = nil,
        changed: Bool = false,
        intent: UpstreamHistoryViewModel.RequestIntent = .appearance
    ) {
        flow.enqueue(label, after: after) {
            await model.request(
                skill: skill,
                localRevision: changed ? UpstreamHistoryLocalRevision(appWriteRevision: 1, watcherEventSequence: 0) : .initial,
                intent: intent
            )
        }
    }
}

@MainActor
extension UpstreamHistoryCacheTestCase {
    func sequenceFixture(
        _ seed: UpstreamHistorySequenceFixture.Seed,
        moved: Bool = false,
        fails: Bool = false,
        edits: UpstreamHistoryLocalEdits = .none,
        measure: (() -> UpstreamHistoryLocalEdits)? = nil
    ) throws -> UpstreamHistorySequenceFixture {
        let skill = installedHistorySkill(recordedHead: String(repeating: "1", count: 40))
        let kept = result(head: String(repeating: "1", count: 40), subject: "kept")
        let fresh = result(head: String(repeating: "2", count: 40), subject: "fresh")
        let otherSkill = installedHistorySkill(name: "Other", commit: String(repeating: "9", count: 40),
                                               recordedHead: String(repeating: "9", count: 40))
        let otherResult = result(head: String(repeating: "9", count: 40), subject: "other skill")
        let calls = HistorySequenceCalls()
        let flow = UpstreamHistorySequenceHarness()
        // Each generated run owns its cache directory; previous schedules cannot seed later ones.
        let disk = UpstreamHistoryCache(directory: cacheDirectory + "/" + UUID().uuidString, fileService: fileService)
        let model = owner(
            cache: disk,
            read: { origin, _, _ in
                if origin.installedCommit == String(repeating: "9", count: 40) {
                    calls.append("otherRead")
                    return otherResult
                }
                calls.append("read")
                if fails { throw GitError.commandFailed(args: [], exitCode: 1, stderr: "sequence offline") }
                return fresh
            },
            head: { _ in
                calls.append("probe")
                if fails { throw GitError.commandFailed(args: [], exitCode: 1, stderr: "sequence offline") }
                return moved ? fresh.headCommit : kept.headCommit
            },
            localEdits: { _, _, _ in measure?() ?? edits }
        )
        switch seed {
        case .empty: break
        case .disk: try seedHistoryDisk(kept, for: skill, in: disk)
        case .memory: try seedHistoryMemory(kept, for: skill, in: model)
        }
        try seedHistoryMemory(otherResult, for: otherSkill, in: model)
        model.flows[otherSkill.id]?.probeSpent = true
        flow.currentSkill = { [weak model] in model?.currentSkillID }
        model.sequenceHooks = flow.hooks
        return UpstreamHistorySequenceFixture(flow: flow, model: model, skill: skill,
                                              otherSkill: otherSkill, otherResult: otherResult,
                                              disk: disk, calls: calls, kept: kept, fresh: fresh)
    }
}

extension UpstreamHistorySequenceFixture {
    func validatePublications() throws {
        for publication in flow.publications {
            guard publication.skillID == publication.visibleSkillID else {
                throw HistorySequenceFailure("Publication source is not the current skill: \(publication)")
            }
            switch publication.state {
            case let .loaded(result), let .refreshing(result), let .loadedWithFailure(result, _):
                let allowed = publication.skillID == otherSkill.id ? [otherResult] : [kept, fresh]
                guard allowed.contains(where: { $0.rows == result.rows && $0.headCommit == result.headCommit }) else {
                    throw HistorySequenceFailure("Another skill's rows were published: \(publication)")
                }
            case .idle, .loading, .failed: break
            }
        }
    }
}
