import Foundation
@testable import Pensieve

final class LockedHistoryProbe {
    private let lock = NSLock()
    private var callCount = 0
    private var mainThreadValues: [Bool] = []

    func recordCall() {
        lock.lock()
        callCount += 1
        mainThreadValues.append(Thread.isMainThread)
        lock.unlock()
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadValues.contains(true)
    }
}

func installedHistorySkill(
    name: String = "Demo",
    repo: String = "https://github.com/example/skills",
    path: String = "skills/demo",
    ref: String = "main",
    commit: String = String(repeating: "a", count: 40),
    recordedHead: String? = nil
) -> Skill {
    let skill = Skill(name: name, directoryName: name.lowercased())
    skill.installedOrigin = InstalledOrigin(
        repo: repo,
        path: path,
        ref: ref,
        installedCommit: commit,
        installedTree: "tree",
        contentHash: "sha256:installed",
        installedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    skill.lastCheckedHead = recordedHead
    return skill
}

func historyResult(
    head: String = String(repeating: "b", count: 40),
    localEdits: UpstreamHistoryLocalEdits = .none
) -> UpstreamHistoryResult {
    UpstreamHistoryResult(
        headCommit: head,
        rows: [UpstreamHistoryRow(
            sha: head,
            author: "Author",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Subject",
            filesChanged: 1,
            linesAdded: 2,
            linesRemoved: 1,
            skillMarkdown: .text("# Demo")
        )],
        installedPosition: .at(sha: head),
        hasOlderHistory: false,
        installedBaseline: .files([]),
        localEdits: localEdits,
        windowCount: 1
    )
}

/// The History layout fixture includes a multiline subject and a row without readable Markdown.
func historyTimelineResult(rowCount: Int, hasOlderHistory: Bool = false) -> UpstreamHistoryResult {
    let rows: [UpstreamHistoryRow] = (0..<rowCount).map { index in
        let subject = index == 1 ? "Version 11\nA second subject line" : "Version \(12 - index)"
        let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 - index))
        return UpstreamHistoryRow(
            sha: String(format: "%040x", index + 1),
            author: "Author",
            date: date,
            subject: subject,
            filesChanged: 1,
            linesAdded: 2,
            linesRemoved: 1,
            skillMarkdown: index == 1 ? nil : .text("# Version \(index)")
        )
    }
    return UpstreamHistoryResult(
        headCommit: rows[0].sha,
        rows: rows,
        installedPosition: .at(sha: rows[0].sha),
        hasOlderHistory: hasOlderHistory,
        installedBaseline: .files([]),
        localEdits: .none,
        windowCount: 1
    )
}

@MainActor
func historyOwner(
    read: @escaping UpstreamHistoryViewModel.ReadOperation,
    head: UpstreamHistoryViewModel.HeadOperation? = nil,
    localEdits: @escaping UpstreamHistoryViewModel.LocalEditsOperation = { _, _, _ in .none },
    localDirectory: @escaping UpstreamHistoryViewModel.LocalDirectoryResolver = {
        "/tmp/pensieve-history-tests/" + $0
    },
    cache: UpstreamHistoryCache? = nil,
    onRequest: @escaping UpstreamHistoryViewModel.RequestObserver = { _ in }
) -> UpstreamHistoryViewModel {
    UpstreamHistoryViewModel(
        readOperation: read,
        headOperation: head,
        localEditsOperation: localEdits,
        localDirectory: localDirectory,
        cache: cache,
        requestObserver: onRequest
    )
}

func waitForHistorySemaphore(_ semaphore: DispatchSemaphore) async -> Bool {
    await TestWait.forSemaphore(semaphore)
}

@MainActor
func waitForHistoryCondition(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    await TestWait.until(failureMessage: "History condition did not become true") { condition() }
    return condition()
}

/// A visible value can precede worker completion. Reads and work that can start a read
/// must finish before callers count service calls. A head probe may deliberately remain
/// held while a kept result is visible. An absence observation pumps the actor/run loop
/// for its whole bound so an unmounted view cannot pass before a stray task starts.
@MainActor
func waitForSettledHistory(
    owner: UpstreamHistoryViewModel,
    expected: UpstreamHistoryLoadState,
    timeout: Duration = .seconds(TestWait.hostedActionTimeoutSeconds),
    observeFor: Duration = .zero,
    failureMessage: String,
    ready: @escaping @MainActor () -> Bool = { true }
) async {
    let clock = ContinuousClock()
    let observationEnd = clock.now.advanced(by: observeFor)
    await TestWait.until(timeout: timeout, failureMessage: failureMessage, diagnostics: {
        "expected=\(expected); actual=\(owner.state); jobs=\(owner.flows.values.reduce(0) { $0 + $1.jobs.count })"
    }, {
        ready() && clock.now >= observationEnd && owner.state == expected
            && owner.flows.values.allSatisfy { flow in
                flow.jobs.values.allSatisfy { job in
                    if case .probe = job.purpose { return true }
                    return false
                }
            }
    })
}
