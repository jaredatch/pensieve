import SwiftData
import XCTest
@testable import Pensieve

final class GitCompletionReviewTests: XCTestCase {
    func testUnconfirmedHintsShareOneBatchDiagnosticProbe() {
        var probes = 0
        let diagnostics = UpdateBatchDiagnostics { probes += 1; return .licenseNotAccepted }
        for detail in ["Xcode license not accepted", "xcrun: error: invalid active developer path"] {
            let failure = diagnostics.classify(GitError.commandFailed(args: ["rev-parse"], exitCode: 69, stderr: detail))
            XCTAssertTrue(failure.environment)
            XCTAssertEqual(failure.usability, .licenseNotAccepted)
            XCTAssertEqual(failure.error as? GitError, .unusable(.licenseNotAccepted))
        }
        XCTAssertEqual(probes, 1, "unconfirmed hints share the batch diagnostic")
        let confirmed = diagnostics.classify(GitError.commandFailed(args: ["clone"], exitCode: 69,
            stderr: "Xcode license not accepted", confirmingProbe: .usable))
        XCTAssertFalse(confirmed.environment)
        XCTAssertEqual(confirmed.usability, .usable)
        XCTAssertEqual(probes, 1, "a carried answer needs no diagnostic")
    }

    func testRunnerConfirmsStdoutHintWhenStderrIsEmpty() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = try fixture.executable("echo 'Xcode license not accepted'; exit 69")
        XCTAssertThrowsError(try git.clone(remote: "https://fixture.test/store.git", into: fixture.root, credential: nil)) {
            XCTAssertEqual($0 as? GitError, .unusable(.licenseNotAccepted))
        }
        let calls = try fixture.files.readFile(at: fixture.trace)
        XCTAssertEqual(calls.components(separatedBy: .newlines).filter { $0 == "--version" }.count, 1)
    }

    func testConfirmedUsableCommandFailureDoesNotProbeAgain() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = try fixture.executable("""
            \(FakeGitScript.skipGlobalOptions)
            if [ "$1" = '--version' ]; then echo 'git version fixture'; exit 0; fi
            echo 'checkout failed for xcrun: error: invalid active developer path' >&2
            exit 128
            """)
        let diagnostics = UpdateBatchDiagnostics(probe: git.probeUsability)
        _ = diagnostics.classify(GitError.unusable(.licenseNotAccepted))
        do {
            try git.clone(remote: "https://fixture.test/store.git", into: fixture.root, credential: nil)
            XCTFail("clone should fail")
        } catch {
            guard case let GitError.commandFailed(_, _, _, answer) = error else { return XCTFail("expected command error") }
            XCTAssertEqual(answer, .usable, "the real confirming answer travels on the error")
            let classified = diagnostics.classify(error)
            XCTAssertFalse(classified.environment)
            XCTAssertEqual(diagnostics.evidence, .usable, "retain the runner’s confirmed usable answer")
            XCTAssertEqual(classified.error as? GitError, error as? GitError)
        }
        let calls = try fixture.files.readFile(at: fixture.trace)
        XCTAssertEqual(calls.components(separatedBy: .newlines).filter { $0 == "--version" }.count, 1)
    }

    func testConflictBestEffortReadsPropagateConfirmedUnusability() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = try fixture.broken(.licenseNotAccepted)
        let reads: [() throws -> Void] = [
            { _ = try git.blob(atStage: 2, path: "skills/example/SKILL.md", in: fixture.root) },
            { _ = try git.conflictedFiles(at: fixture.root) },
            { _ = try git.hasCommitsToPush(at: fixture.root) },
            { _ = try git.headSHA(at: fixture.root) },
            { try git.ensureCommitIdentity(at: fixture.root) }
        ]
        for (index, read) in reads.enumerated() {
            XCTAssertThrowsError(try read(), "read \(index) must preserve the host failure") {
                XCTAssertEqual($0 as? GitError, .unusable(.licenseNotAccepted))
            }
        }
    }

    func testEqualFailureDetailsHaveOneRepresentation() {
        let raw = "failed\n\u{1B}[31mrepo\u{1B}[0m"
        XCTAssertEqual(GitUsability.failed(GitFailureDetail(raw)), .failed(GitFailureDetail("failed\nrepo")))
        XCTAssertEqual(GitUsability.failed(GitFailureDetail(raw)), .failed(GitFailureDetail("failed repo")))
    }

    func testConflictBlobReadFailureThrowsWhileBestEffortReadsKeepFallbacks() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let git = try fixture.executable("echo 'ordinary missing revision' >&2; exit 128")
        XCTAssertThrowsError(try git.blob(atStage: 2, path: "missing", in: fixture.root))
        XCTAssertTrue(try git.conflictedFiles(at: fixture.root).isEmpty)
        XCTAssertFalse(try git.hasCommitsToPush(at: fixture.root))
        XCTAssertNil(try git.headSHA(at: fixture.root))
        XCTAssertNoThrow(try git.ensureCommitIdentity(at: fixture.root))
    }

    @MainActor
    func testMidResolutionBlobFailureNamesGitInsteadOfChangedConflicts() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        // The successful fake fetch below leaves a real fetched commit for the guarded rebase.
        try TestPaths.git.runOrThrow(["-C", fixture.root, "fetch", ".", "HEAD:refs/remotes/origin/main"], in: nil)
        let blob = try TestPaths.git.runOrThrow(["-C", fixture.root, "rev-parse", "HEAD:skills/example/SKILL.md"], in: nil)
            .stdout.trimmingCharacters(in: .newlines)
        let git = try fixture.executable("""
            simulate_failure() {
                \(FakeGitScript.skipGlobalOptions)
                if [ "$1" = show ]; then touch '\(fixture.failureSwitch)'; fi
                if [ -f '\(fixture.failureSwitch)' ]; then
                  echo 'Xcode license not accepted' >&2; exit 69
                fi
                case "$1" in
                  --version) echo 'git version fixture'; exit 0 ;;
                  fetch) exit 0 ;;
                  rebase)
                    printf '%s\\n' \\
                      '0 0000000000000000000000000000000000000000\tskills/example/SKILL.md' \\
                      '100644 \(blob) 2\tskills/example/SKILL.md' \\
                      '100644 \(blob) 3\tskills/example/SKILL.md' |
                      /usr/bin/git -C '\(fixture.root)' update-index --index-info
                    exit 1 ;;
                  diff) if [ "$2" = '--name-only' ]; then printf 'skills/example/SKILL.md\\0'; exit 0; fi ;;
                esac
            }
            simulate_failure "$@"
            exec /usr/bin/git "$@"
            """)
        let engine = SyncEngine(gitService: git, lockPath: fixture.support + "/sync.lock")
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let picks = ["skills/example/SKILL.md": ResolutionPick(side: .thisMachine,
            expectedThis: Data("current".utf8), expectedOther: Data("remote".utf8))]
        XCTAssertThrowsError(try engine.resolveConflicts(root: fixture.root, picks: picks,
            credential: nil, context: container.mainContext)) {
            XCTAssertEqual($0 as? GitError, .unusable(.licenseNotAccepted))
        }
    }

}
