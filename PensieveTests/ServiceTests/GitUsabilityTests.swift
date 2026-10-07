import XCTest
@testable import Pensieve

final class GitUsabilityTests: XCTestCase {
    func testProbeClassifiesStandInExecutablesAndLaunchFailure() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        let states: [GitUsability] = [.usable, .licenseNotAccepted, .developerToolsMissing,
                                      .failed(GitFailureDetail("unexpected failure"))]
        for state in states {
            XCTAssertEqual(try fixture.broken(state).probeUsability(), state)
        }
        let missing = GitService(executablePath: fixture.base + "/missing")
        guard case let .failed(detail) = try missing.probeUsability() else { return XCTFail("launch failure must be unknown") }
        XCTAssertFalse(detail.text.isEmpty)
        XCTAssertEqual(try GitService().probeUsability(), .usable)
    }

    func testGeneratedRemoteOutcomeSweep() throws {
        let samples: [RemoteSample] = [
            RemoteSample(exit: 0, output: "https://fixture.test/store.git", expected: .url("https://fixture.test/store.git")),
            RemoteSample(exit: 0, expected: .url(nil)),
            RemoteSample(exit: 2, error: "No such remote", expected: .url(nil)),
            RemoteSample(exit: 128, error: "fatal: not a git repository", hasGitEntry: false, expected: .url(nil)),
            RemoteSample(exit: 128, error: "fatal: not a git repository", expected: .repository),
            RemoteSample(exit: 128, error: "permission denied", expected: .repository),
            RemoteSample(exit: 1, error: "repository config unreadable", expected: .repository),
            RemoteSample(exit: 69, error: "Xcode license: sudo xcodebuild -license",
                         versionFails: true, expected: .unusable(.licenseNotAccepted)),
            RemoteSample(exit: 1, error: "xcrun: error: invalid active developer path",
                         versionFails: true, expected: .unusable(.developerToolsMissing)),
            RemoteSample(exit: 0, launches: false, expected: .launchFailure)
        ]
        for (index, sample) in samples.enumerated() {
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            if sample.hasGitEntry { try fixture.files.createDirectory(at: fixture.root + "/.git") }
            let standIn = try fixture.executable("""
                if [ "$1" = '--version' ] && [ '\(sample.versionFails)' != true ]; then
                    echo 'git version fixture'; exit 0
                fi
                if [ "$3" = 'rev-parse' ]; then echo '.git'; exit 0; fi
                printf '%s\\n' '\(sample.output)'
                printf '%s\\n' '\(sample.error)' >&2
                exit \(sample.exit)
                """)
            let git = sample.launches ? standIn : GitService(executablePath: fixture.base + "/missing")
            assertRemoteAnswer(git, sample: sample, fixture: fixture, index: index)
        }
    }

    func testDanglingGitEntryIsUnknownAndDoesNotFollowLink() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.files.createSymlink(at: fixture.root + "/.git", pointingTo: fixture.base + "/missing")
        XCTAssertThrowsError(try GitService().remoteURL(at: fixture.root)) { error in
            guard case GitError.repositoryUnreadable = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(fixture.files.isSymlink(at: fixture.root + "/.git"))
    }

    func testSetRemoteRefusesUnknownWithoutRemoteMutation() throws {
        let fixture = try GitFailureFixture()
        defer { try? fixture.remove() }
        try fixture.seedRepository()
        let before = try fixture.snapshot()
        let git = try fixture.broken(.licenseNotAccepted)
        XCTAssertThrowsError(try git.setRemote("https://fixture.test/other.git", at: fixture.root))
        XCTAssertEqual(try fixture.snapshot(), before)
        let calls = try fixture.files.readFile(at: fixture.trace)
        XCTAssertFalse(calls.contains("remote add"))
        XCTAssertFalse(calls.contains("remote set-url"))
    }

    private enum RemoteAnswer {
        case url(String?), repository, unusable(GitUsability), launchFailure
    }

    private struct RemoteSample {
        let exit: Int
        var output = ""
        var error = ""
        var hasGitEntry = true
        var launches = true
        var versionFails = false
        let expected: RemoteAnswer
    }

    private func assertRemoteAnswer(_ git: GitService, sample: RemoteSample, fixture: GitFailureFixture, index: Int) {
        if case let .url(url) = sample.expected {
            XCTAssertEqual(try git.remoteURL(at: fixture.root), url, "sample \(index)")
            return
        }
        XCTAssertThrowsError(try git.remoteURL(at: fixture.root), "sample \(index)") { error in
            switch (sample.expected, error) {
            case let (.repository, GitError.repositoryUnreadable(path, detail)):
                XCTAssertEqual(path, fixture.root)
                XCTAssertTrue(detail.contains(sample.error))
            case let (.unusable(expected), GitError.unusable(actual)):
                XCTAssertEqual(actual, expected, "sample \(index)")
            case let (.launchFailure, GitError.unusable(.failed(detail))):
                XCTAssertFalse(detail.text.isEmpty)
            default:
                XCTFail("sample \(index): wrong unknown shape: \(error)")
            }
        }
    }

}
