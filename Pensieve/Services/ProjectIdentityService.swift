import Foundation

struct ProjectIdentity: Equatable {
    enum Kind: String, Codable {
        case remote
        case marker
    }

    let kind: Kind
    let key: String
}

protocol ProjectIdentityServiceProtocol {
    func identity(forProjectAt path: String) throws -> ProjectIdentity
    func peekIdentity(forProjectAt path: String) -> ProjectIdentity?
}

struct ProjectIdentityService: ProjectIdentityServiceProtocol {
    private let fileService: FileServiceProtocol

    init(fileService: FileServiceProtocol = FileService()) {
        self.fileService = fileService
    }

    func identity(forProjectAt path: String) throws -> ProjectIdentity {
        let project = try fileService.requireProjectDirectory(at: path)
        if let existing = peekIdentity(forProjectAt: path) {
            return existing
        }

        let markerPath = path + "/.pensieve-project"
        let id = UUID().uuidString
        let content = """
        # Pensieve project identity — committed so this project is recognized across machines.
        id = \(id)
        format_version = 1
        """
        try fileService.writeFileInProject(at: markerPath, content: content, project: project)
        return ProjectIdentity(kind: .marker, key: id)
    }

    /// Read-only identity probe for previews: returns the existing identity (a parseable git remote,
    /// or an existing `.pensieve-project` marker) without creating anything. Returns nil for a
    /// directory that has neither — the marker is created only by `identity(forProjectAt:)` at the
    /// registration "Add" action; it does not rewrite an existing identity.
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

    /// Waiting cleanup compares every carried identity. A failed source read cannot prove a
    /// mismatch, even when another source matches. This probe never creates a marker.
    func existingIdentityKeys(forProjectAt path: String) throws -> Set<String> {
        var keys: Set<String> = []
        let gitPath = path + "/.git"
        let kind = try fileService.entryTypeWithoutFollowingLinks(at: gitPath)
        var gitDirectory = kind == .directory
        if kind == .symlink { gitDirectory = try fileService.directoryExistsFollowingLinks(at: gitPath) }
        if gitDirectory, let config = try identitySource(at: path + "/.git/config"),
           let origin = Self.parseOriginURL(fromGitConfig: config) {
            guard let key = Self.normalizeRemoteURL(origin) else { throw CocoaError(.fileReadCorruptFile) }
            keys.insert(key)
        }
        if let marker = try identitySource(at: path + "/.pensieve-project") {
            guard let key = Self.parseMarkerID(from: marker) else { throw CocoaError(.fileReadCorruptFile) }
            keys.insert(key)
        }
        return keys
    }

    private func identitySource(at path: String) throws -> String? {
        do { return try fileService.readFile(at: path) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && (error.code == Int(ENOENT) || error.code == Int(ENOTDIR)) {
            return nil
        }
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
