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
