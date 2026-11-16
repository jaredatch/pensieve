import SwiftData
import XCTest
@testable import Pensieve

/// Real engines and presentation boundaries; only git's failure timing is controlled.
/// All link inspection uses the caller's temporary installer, never a host command folder.
@MainActor
final class SyncLogCommandFixture {
    enum Route: CaseIterable {
        case cycleAbort, cycleReturn, windowAbort, windowFinalAbort, windowReturn, windowApply
    }
    let disk: GitFailureFixture
    let container: ModelContainer
    let audit: SyncAudit

    init() throws {
        disk = try GitFailureFixture()
        container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        audit = SyncAudit(appSupport: disk.support)
    }

    func git(_ route: Route) -> SyncConflictResolutionTests.StubGit {
        let abort = GitError.commandFailed(args: ["-C", disk.root, "rebase", "--abort"], exitCode: 128,
                                          stderr: "fatal: index.lock in \(disk.root)")
        let pull = GitError.commandFailed(args: ["rebase"], exitCode: 1, stderr: "fatal: pull refused")
        let git = SyncConflictResolutionTests.StubGit(conflictPath: "skills/x/SKILL.md",
            pullError: route == .cycleReturn || route == .windowReturn ? pull : nil,
            abortError: route == .windowApply ? nil : abort)
        if route == .cycleAbort || route == .windowAbort { git.initialAbortError = abort }
        return git
    }

    func engine(_ git: GitServiceProtocol) -> SyncEngine {
        SyncEngine(gitService: git, fileService: disk.files, lockPath: disk.support + "/sync.lock")
    }

    func coordinator(_ git: GitServiceProtocol, installer: CommandLinkInstaller?) async -> SyncCoordinator {
        let coordinator = SyncCoordinator(modelContainer: container)
        await coordinator.configure(engine: engine(git), git: git, credentials: InMemoryCredentialStore(),
            root: disk.root, audit: audit, machine: (InertMachineIdentity(), InertMachineStateService()),
            commandLink: installer)
        return coordinator
    }

    func window(_ git: GitServiceProtocol, installer: CommandLinkInstaller?) -> ConflictResolutionModel {
        ConflictResolutionModel(engine: engine(git), git: git, credentials: InMemoryCredentialStore(),
            root: disk.root, audit: audit, commandLink: installer, steps: SyncStepModel())
    }

    func message(_ route: Route, installer: CommandLinkInstaller?) async -> String {
        let git = git(route)
        if route == .cycleAbort || route == .cycleReturn {
            return Self.message(await coordinator(git, installer: installer).runCycle())
        }
        let model = window(git, installer: installer)
        await model.loadAndReport(container: container)
        if route == .windowApply {
            model.choose("skill:x", .thisMachine)
            // A fresh rebase for Apply first aborts harmlessly, then pull and recovery both fail.
            let failure = self.git(.windowReturn)
            git.pullError = failure.pullError
            git.abortError = failure.abortError
            // The stub already pulled while loading; clear that attempt before the new operation.
            git.resetPullAttempt()
            await model.applyAndReport(container: container)
        }
        return Self.message(model)
    }

    static func message(_ result: SyncCycleResult) -> String {
        if case let .failed(message) = result { return message }
        XCTFail("Expected failed cycle, got \(result)")
        return ""
    }

    static func message(_ model: ConflictResolutionModel) -> String {
        if case let .error(message) = model.phase { return message }
        XCTFail("Expected failed conflict operation, got \(model.phase)")
        return ""
    }

    static let shortSentence = "Run pensieve log in Terminal for the details."

    // Expected shell syntax is deliberately independent of the production command formatter.
    static func sentence(_ executable: String, quoted: Bool = false) -> String {
        let path = quoted ? "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'" : executable
        return "Run " + path + " log in Terminal for the details."
    }

    func assertMessage(_ message: String, endsWith sentence: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(String(message.suffix(sentence.count)), sentence, message, file: file, line: line)
        for secret in [disk.root, "fatal:", "index.lock", "pull refused", "Install"] {
            XCTAssertFalse(message.contains(secret), message, file: file, line: line)
        }
    }

    func statusText(_ message: String) -> String {
        let model = SyncModel(git: disk.paths.makeGitService(), root: disk.root)
        model.apply(.failed(message))
        if case let .error(text) = model.state { return text }
        XCTFail("Expected sync status error")
        return ""
    }

    func assertRuns(_ rendered: String, file: StaticString = #filePath, line: UInt = #line) async {
        let start = rendered.range(of: "Run ")?.upperBound ?? rendered.endIndex
        let end = rendered.range(of: " in Terminal", range: start..<rendered.endIndex)?.lowerBound ?? start
        let command = String(rendered[start..<end])
        XCTAssertFalse(command.isEmpty, rendered, file: file, line: line)
        let result: (Int32?, String)
        do {
            result = try await BlockingWork.run {
                try CommandLinkFixture.run("/bin/zsh", arguments: ["-f", "-c",
                    command + " --app-support '" + self.disk.support + "'"],
                    environment: ["PATH": "/usr/bin:/bin", "HOME": self.disk.base,
                                  "CFFIXED_USER_HOME": self.disk.base])
            }
        } catch {
            XCTFail("Shell could not launch: \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(result.0, 0, result.1, file: file, line: line)
        let log = (try? disk.files.readFile(at: disk.support + "/daemon.log")) ?? ""
        let lastLine = log.split(separator: "\n").last.map(String.init) ?? "missing audit line"
        XCTAssertTrue(lastLine.contains(" failed "), lastLine, file: file, line: line)
        XCTAssertTrue(result.1.contains(lastLine), result.1, file: file, line: line)
    }
}
