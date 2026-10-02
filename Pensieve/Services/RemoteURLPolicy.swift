import Foundation

/// The git transport a remote uses. Drives auth (ssh-agent vs a PAT) and which fields the setup sheet
/// shows. (PLAN-08 / 08.3). Defined here — not in `SyncSetupModel` — so the daemon target, which globs
/// `RemoteURLPolicy` for `RemoteSpec`/`RemoteURLPolicy`, compiles without dragging in a SwiftUI ViewModel
/// (PLAN-12 / 12.2).
enum GitTransport: Equatable {
    case ssh
    case https
}

/// A validated, transport-classified git remote. `host` keys the Keychain credential (08.2). `url` is
/// the normalized (trimmed) original — for https it NEVER carries userinfo (a secret must not ride the
/// URL into argv or `.git/config`; the policy rejects that form).
struct RemoteSpec: Equatable {
    let url: String
    let host: String
    let transport: GitTransport
}

/// The single, pure remote-URL admission policy (no git, no FS). `SyncSetupModel.parseRemote` (connect
/// time) and `SyncEngine`'s sync-time re-validation both route through `parse`, so a hand-edited
/// `.git/config` that sets `origin` to ANY form connect would reject (ext::, http://, git://, file://,
/// https-userinfo, dash-leading host, interior newline) can't ride an unchecked path (C1 defense in depth).
enum RemoteURLPolicy {
    /// Trim, reject a leading `-` (git-option injection) and any interior newline, then classify
    /// transport with a strict ALLOWLIST. Returns nil for anything not https / ssh / scp-style. Transport
    /// is classified BEFORE the https-userinfo ban so a legitimate scp-style `git@host:path` (its `@` is
    /// the ssh user) is accepted while `https://user:tok@host` (a secret in the URL) is rejected. `ext::`
    /// / `fd::` / `git://` / `http://` / `file://` / a bare path all return nil.
    static func parse(_ raw: String) -> RemoteSpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        // C2: reject an interior newline. Trimming strips only leading/trailing newlines; a middle `\n`
        // survives and could smuggle a second line/command into a downstream consumer of the URL.
        guard !trimmed.contains(where: \.isNewline) else { return nil }
        // Reject git remote-helper syntax `transport::address` (ext::, fd::, transport::, …) FIRST —
        // BEFORE scp-style classification. A valid `ext::sh -c …` URL git EXECUTES (RCE), and it can hide
        // a fake scp-style `@host:path` tail (e.g. `ext::sh -c '… # @h:x'`) that would otherwise make the
        // classifier return a benign-looking `.ssh` spec whose `url` is still the full malicious string.
        // The `--` terminators in GitService do NOT disable remote helpers; only rejecting it here does.
        // A remote-helper's transport is the bare `[A-Za-z0-9+.-]` token before the first `::` (so an
        // IPv6 `ssh://[…::…]` host, whose prefix contains `/`/`:`/`[`, is NOT caught).
        if let dcolon = trimmed.range(of: "::") {
            let prefix = trimmed[..<dcolon.lowerBound]
            let isHelperTransport = !prefix.isEmpty
                && prefix.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
            if isHelperTransport { return nil }
        }

        if let spec = parseScpStyle(trimmed) { return spec }   // scp-style ssh, no scheme

        guard let scheme = scheme(of: trimmed) else { return nil }
        switch scheme {
        case "ssh":   return parseSSH(trimmed)
        case "https": return parseHTTPS(trimmed)
        default:      return nil   // ext, fd, git, http, file, transport::… — all rejected
        }
    }

    /// Convenience predicate: true when `parse` rejects the remote.
    static func isRejected(_ raw: String) -> Bool { parse(raw) == nil }

    // MARK: - URL parsing helpers (moved verbatim from SyncSetupModel; only host(fromAuthority:) changed)

    /// The `scheme` of a proper `scheme://…` URL, lowercased. Requires the `://` form, so `ext::sh`
    /// (no `//`) has NO scheme here and is rejected by the caller.
    private static func scheme(of url: String) -> String? {
        guard let range = url.range(of: "://") else { return nil }
        let scheme = String(url[url.startIndex..<range.lowerBound]).lowercased()
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return scheme
    }

    /// scp-style `user@host:path` (no scheme). Rejects anything containing `://` (that's a scheme URL,
    /// handled elsewhere) so `https://user@host/x` is NOT mistaken for scp-style.
    private static func parseScpStyle(_ url: String) -> RemoteSpec? {
        guard !url.contains("://"), let atIndex = url.firstIndex(of: "@") else { return nil }
        let afterAt = url[url.index(after: atIndex)...]
        guard let colonIndex = afterAt.firstIndex(of: ":") else { return nil }
        let host = String(afterAt[afterAt.startIndex..<colonIndex])
        let path = afterAt[afterAt.index(after: colonIndex)...]
        guard !host.isEmpty, !host.hasPrefix("-"), !path.isEmpty else { return nil }
        return RemoteSpec(url: url, host: host, transport: .ssh)
    }

    private static func parseSSH(_ url: String) -> RemoteSpec? {
        guard let authority = authority(of: url), let host = host(fromAuthority: authority) else { return nil }
        return RemoteSpec(url: url, host: host, transport: .ssh)
    }

    /// https — REJECT any userinfo (`user@` / `user:tok@` / `user%40…@`): a secret must never ride the
    /// URL. The token comes only from the token field → Keychain → askpass (§E).
    private static func parseHTTPS(_ url: String) -> RemoteSpec? {
        guard let authority = authority(of: url), !authority.contains("@") else { return nil }
        guard let host = host(fromAuthority: authority) else { return nil }
        return RemoteSpec(url: url, host: host, transport: .https)
    }

    /// The authority segment after `scheme://`, up to the first `/`, `?`, or `#`.
    private static func authority(of url: String) -> String? {
        guard let range = url.range(of: "://") else { return nil }
        let rest = url[range.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = String(rest[rest.startIndex..<end])
        return authority.isEmpty ? nil : authority
    }

    /// The host from an authority, stripping any `user@` prefix (ssh only) and any `:port` suffix.
    private static func host(fromAuthority authority: String) -> String? {
        var hostPort = authority
        if let atIndex = hostPort.lastIndex(of: "@") {
            hostPort = String(hostPort[hostPort.index(after: atIndex)...])
        }
        if hostPort.hasPrefix("[") {                                   // C6: IPv6 literal, e.g. [::1]:22
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            // Same dash-leading ban as the non-bracket path: `ssh://[-oProxyCommand=…]/x` would otherwise
            // smuggle a dash-host past the whole-remote leading-dash check (the remote starts `ssh://[`).
            return (host.isEmpty || host.hasPrefix("-")) ? nil : host
        }
        let host = hostPort.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPort
        // Reject a dash-leading host (defense-in-depth vs an `ssh://-oProxyCommand=…` style host that
        // an older git could treat as an ssh option — orthogonal to the whole-remote leading-dash ban).
        return (host.isEmpty || host.hasPrefix("-")) ? nil : host
    }
}
