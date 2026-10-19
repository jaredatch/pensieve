import Foundation
import os

struct ProjectIdentity: Equatable {
    enum Kind: String, Codable {
        case remote
        case marker
    }

    let kind: Kind
    let key: String
}

protocol ProjectIdentityServiceProtocol {
    func withIdentity<Value>(forProjectAt path: String, save: (ProjectIdentity) throws -> Value) throws -> Value
    func peekIdentity(forProjectAt path: String) -> ProjectIdentity?
}

struct ProjectIdentityService: ProjectIdentityServiceProtocol {
    private static let markerLock = NSLock()
    private let fileService: FileServiceProtocol

    init(fileService: FileServiceProtocol = FileService()) {
        self.fileService = fileService
    }

    /// Keep competing registrations from replacing or adopting a marker until its save succeeds.
    /// The callback must end at persistence; later work belongs outside this transaction.
    func withIdentity<Value>(forProjectAt path: String, save: (ProjectIdentity) throws -> Value) throws -> Value {
        let project = try fileService.requireProjectDirectory(at: path)
        return try Self.markerLock.withLock {
            if let existing = peekIdentity(forProjectAt: path) { return try save(existing) }
            let markerPath = path + "/.pensieve-project"
            // Preparation can race another writer. Re-read before creating any marker.
            let previousMarker = try? fileService.readFile(at: markerPath)
            if let previousMarker, let id = Self.parseMarkerID(from: previousMarker) {
                return try save(ProjectIdentity(kind: .marker, key: id))
            }
            let hadMarker = try fileService.entryExistsWithoutFollowingLinks(at: markerPath)
            let id = UUID().uuidString
            let content = """
            # Pensieve project identity — committed so this project is recognized across machines.
            id = \(id)
            format_version = 1
            """
            try fileService.writeFileInProject(at: markerPath, content: content, project: project)
            do {
                return try save(ProjectIdentity(kind: .marker, key: id))
            } catch {
                do {
                    if try fileService.readFile(at: markerPath) == content {
                        if let previousMarker {
                            try fileService.writeFileInProject(at: markerPath, content: previousMarker, project: project)
                        } else if !hadMarker {
                            try fileService.deleteFile(at: markerPath)
                        }
                    }
                } catch {
                    let reason = error.localizedDescription
                    Logger(subsystem: "com.jaredatch.pensieve", category: "projects")
                        .warning("Project identity marker cleanup failed at \(markerPath): \(reason, privacy: .public)")
                }
                throw error
            }
        }
    }

    /// Read-only identity probe for previews: returns the existing identity (a parseable git remote,
    /// or an existing `.pensieve-project` marker) without creating anything. Returns nil for a
    /// directory that has neither. Registration finalizes identity around its save; previews
    /// neither create a marker nor rewrite an existing identity.
    func peekIdentity(forProjectAt path: String) -> ProjectIdentity? {
        // Git worktrees/submodules use a .git file; those intentionally fall through to marker identity.
        if fileService.directoryExists(at: path + "/.git"),
           let configText = try? fileService.readFile(at: path + "/.git/config"),
           let origin = Self.parseOriginURL(fromGitConfig: configText),
           let key = Self.normalizeRemoteURL(origin) {
            return ProjectIdentity(kind: .remote, key: key)
        }

        let markerPath = path + "/.pensieve-project"
        if let markerText = try? fileService.readFile(at: markerPath),
           let id = Self.parseMarkerID(from: markerText) {
            return ProjectIdentity(kind: .marker, key: id)
        }

        return nil
    }

    /// Canonical cross-machine key from a git remote URL, or nil if unparseable.
    static func normalizeRemoteURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsed: (host: String, path: String)?
        if let scheme = trimmed.range(of: "://") {
            parsed = parseURLForm(String(trimmed[scheme.upperBound...]))
        } else {
            parsed = parseSCPForm(trimmed)
        }
        guard let parsed else { return nil }

        var host = parsed.host
        var path = parsed.path

        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }

        host = host.lowercased()
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return host + "/" + path
    }

    private static func parseURLForm(_ raw: String) -> (host: String, path: String)? {
        var rest = raw
        if let fragment = rest.firstIndex(of: "#") { rest = String(rest[..<fragment]) }
        if let query = rest.firstIndex(of: "?") { rest = String(rest[..<query]) }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let rawAuthority = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        var authority = stripUserPrefix(rawAuthority)
        if let colon = authority.firstIndex(of: ":") {
            authority = String(authority[..<colon])
        }
        return (authority, path)
    }

    private static func parseSCPForm(_ raw: String) -> (host: String, path: String)? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let host = stripUserPrefix(String(raw[..<colon]))
        let path = String(raw[raw.index(after: colon)...])
        return (host, path)
    }

    private static func stripUserPrefix(_ raw: String) -> String {
        guard let at = raw.lastIndex(of: "@") else { return raw }
        return String(raw[raw.index(after: at)...])
    }

    /// The `url = ...` of the `[remote "origin"]` section, or nil.
    static func parseOriginURL(fromGitConfig text: String) -> String? {
        var inOrigin = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = (line == "[remote \"origin\"]")
                continue
            }
            guard inOrigin, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard key == "url" else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The validated UUID from a `.pensieve-project` marker's `id = ...` line, or nil.
    static func parseMarkerID(from text: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard key == "id" else { continue }
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            return UUID(uuidString: value) != nil ? value : nil
        }
        return nil
    }
}
