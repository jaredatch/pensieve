import XCTest
@testable import Pensieve

/// PLAN-10 / 10.3 — the pure remote-URL admission policy (moved out of SyncSetupModel), plus the C2
/// interior-newline reject and the C6 IPv6/bracketed-host fixes.
final class RemoteURLPolicyTests: XCTestCase {
    func testAcceptsSSHScpAndHTTPS() {
        XCTAssertEqual(
            RemoteURLPolicy.parse("git@github.com:octocat/pensieve-skills.git"),
            RemoteSpec(url: "git@github.com:octocat/pensieve-skills.git", host: "github.com", transport: .ssh)
        )
        XCTAssertEqual(RemoteURLPolicy.parse("ssh://git@host.example/path.git")?.transport, .ssh)
        XCTAssertEqual(RemoteURLPolicy.parse("ssh://git@host.example/path.git")?.host, "host.example")
        XCTAssertEqual(
            RemoteURLPolicy.parse("https://github.com/octocat/x.git"),
            RemoteSpec(url: "https://github.com/octocat/x.git", host: "github.com", transport: .https)
        )
    }

    /// C6: an IPv6 ssh remote parses its host as the literal between the brackets, not "[".
    func testAcceptsIPv6SSHHostBetweenBrackets() {
        let spec = RemoteURLPolicy.parse("ssh://git@[::1]:22/x")
        XCTAssertEqual(spec?.transport, .ssh)
        XCTAssertEqual(spec?.host, "::1", "IPv6 host is the literal between [ ], ignoring :port")
    }

    /// Iterates the SHARED reject list (`RemoteURLTestVectors.rejected`) — the same list the sync-time
    /// gating test uses, so connect and sync are provably gated over the identical class set.
    func testRejectsEveryDisallowedForm() {
        for input in RemoteURLTestVectors.rejected {
            XCTAssertNil(RemoteURLPolicy.parse(input), "should reject \(input)")
        }
    }

    func testIsRejectedMatchesParse() {
        XCTAssertTrue(RemoteURLPolicy.isRejected("file:///tmp/x"))
        XCTAssertFalse(RemoteURLPolicy.isRejected("https://github.com/octocat/x.git"))
    }
}
