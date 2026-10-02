import Foundation

/// Canonical remote-URL test vectors shared by the connect-time policy tests (`RemoteURLPolicyTests`)
/// and the sync-time re-validation tests (`SyncEngineRemoteValidationTests`), so the frozen Stage 10.3
/// acceptance — a tampered origin in EACH rejected class is rejected at sync time, "parameterized over
/// the same class list" as connect — is gated over the IDENTICAL list at both layers, with no drift.
/// (PLAN-10 / 10.3)
enum RemoteURLTestVectors {
    /// Every rejected class. `RemoteURLPolicy.parse` returns nil for each; the sync-time guard throws
    /// `SyncError.rejectedRemote` for each (a non-empty stored `origin` passes the `!= nil` check, then
    /// `parse` rejects it) BEFORE any git op.
    static let rejected: [String] = [
        "", "   ", "not a url", "/Users/me/repo",
        "ext::sh -c 'touch /tmp/x'", "fd::0", "--upload-pack=touch /tmp/x",
        "git://github.com/x.git", "http://github.com/x.git", "file:///tmp/x",
        "https://user:tok@github.com/octocat/x.git", "https://user@github.com/x.git",
        "https://user%40example.com:tok@host/x.git",
        "ssh://-oProxyCommand=touch${IFS}x/path", "git@-host:path",
        // remote-helper URLs hiding a fake scp-style `@h:x` tail to fool the classifier
        "ext::sh -c 'touch /tmp/pwn # @h:x'", "fd::0@h:x", "transport::addr@h:x",
        // C6: a bracketed dash-host must be rejected like the bare dash-host
        "ssh://[-oProxyCommand=touch${IFS}x]/path",
        // C2: an interior newline (trimming strips only the ends)
        "https://github.com/x.git\nrm -rf /", "ssh://git@host.example/pa\nth"
    ]
}
