import Foundation

enum SkillInstallURLParseError: Error, Equatable, LocalizedError {
    case unsupportedURL
    case commitLink

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            "not a supported GitHub URL"
        case .commitLink:
            "commit links aren't supported — use a branch link"
        }
    }
}

struct SkillInstallURL: Equatable {
    enum Form: Equatable {
        case repo
        case tree
        case blob
    }

    let repo: String
    let cloneRemote: String
    let ref: String?
    let path: String?
    let form: Form

    static func parse(_ pasted: String) -> SkillInstallURL? {
        switch parseResult(pasted) {
        case let .success(parsed):
            parsed
        case .failure:
            nil
        }
    }

    static func parseResult(_ pasted: String) -> Result<SkillInstallURL, SkillInstallURLParseError> {
        do {
            return .success(try parseValidated(pasted))
        } catch let error as SkillInstallURLParseError {
            return .failure(error)
        } catch {
            return .failure(.unsupportedURL)
        }
    }

    private static func parseValidated(_ pasted: String) throws -> SkillInstallURL {
        let segments = try validatedSegments(pasted)
        let owner = segments[0]
        let repository = segments[1]

        if segments.count == 2 {
            return try parseRepositoryForm(owner: owner, repository: repository)
        }
        return try parseTargetForm(owner: owner, repository: repository, segments: segments)
    }

    private static func validatedSegments(_ pasted: String) throws -> [String] {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = canonicalizeShorthand(trimmed)
        guard !canonical.isEmpty, !canonical.contains(where: \.isNewline) else {
            throw SkillInstallURLParseError.unsupportedURL
        }
        guard let components = URLComponents(string: canonical),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              hasBareGitHubAuthority(canonical),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              let segments = decodedPathSegments(components.percentEncodedPath),
              segments.count >= 2
        else {
            throw SkillInstallURLParseError.unsupportedURL
        }
        let owner = segments[0]
        let repository = segments[1]
        guard isGitHubOwner(owner), isGitHubRepository(repository) else {
            throw SkillInstallURLParseError.unsupportedURL
        }
        return segments
    }

    /// Shorthand the pasteboard produces: a bare `github.com/…` or `www.github.com/…` with no scheme.
    /// Only these two exact prefixes are rewritten; everything downstream (scheme, host, the exact bare
    /// authority, userinfo/port/query/fragment rejection) is unchanged, so no new host shape is admitted.
    private static func canonicalizeShorthand(_ trimmed: String) -> String {
        guard !trimmed.contains("://") else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("github.com/") { return "https://" + trimmed }
        if lower.hasPrefix("www.github.com/") { return "https://github.com/" + trimmed.dropFirst("www.github.com/".count) }
        return trimmed
    }

    private static func parseRepositoryForm(
        owner: String,
        repository: String
    ) throws -> SkillInstallURL {
        var normalizedRepository = repository
        if normalizedRepository.hasSuffix(".git") {
            normalizedRepository.removeLast(4)
        }
        guard isGitHubRepository(normalizedRepository),
              let remotes = reconstructedRemotes(owner: owner, repository: normalizedRepository)
        else {
            throw SkillInstallURLParseError.unsupportedURL
        }
        return SkillInstallURL(
            repo: remotes.repo,
            cloneRemote: remotes.clone,
            ref: nil,
            path: nil,
            form: .repo
        )
    }

    private static func parseTargetForm(
        owner: String,
        repository: String,
        segments: [String]
    ) throws -> SkillInstallURL {
        guard segments.count >= 4,
              !repository.hasSuffix(".git"),
              let remotes = reconstructedRemotes(owner: owner, repository: repository)
        else {
            throw SkillInstallURLParseError.unsupportedURL
        }

        let formSegment = segments[2]
        let ref = segments[3]
        if isCommitSHA(ref) {
            throw SkillInstallURLParseError.commitLink
        }
        guard isPlausibleRef(ref) else {
            throw SkillInstallURLParseError.unsupportedURL
        }

        switch formSegment {
        case "tree":
            let pathSegments = Array(segments.dropFirst(4))
            guard !pathSegments.isEmpty else {
                throw SkillInstallURLParseError.unsupportedURL
            }
            return SkillInstallURL(
                repo: remotes.repo,
                cloneRemote: remotes.clone,
                ref: ref,
                path: pathSegments.joined(separator: "/"),
                form: .tree
            )
        case "blob":
            let fileSegments = Array(segments.dropFirst(4))
            guard fileSegments.last == "SKILL.md" else {
                throw SkillInstallURLParseError.unsupportedURL
            }
            return SkillInstallURL(
                repo: remotes.repo,
                cloneRemote: remotes.clone,
                ref: ref,
                path: fileSegments.dropLast().joined(separator: "/"),
                form: .blob
            )
        default:
            throw SkillInstallURLParseError.unsupportedURL
        }
    }

    private static func decodedPathSegments(_ percentEncodedPath: String) -> [String]? {
        guard percentEncodedPath.hasPrefix("/") else { return nil }
        var encodedSegments = percentEncodedPath.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        if encodedSegments.last == "" {
            encodedSegments.removeLast()
        }

        var decodedSegments: [String] = []
        for encodedSegment in encodedSegments {
            guard let segment = encodedSegment.removingPercentEncoding,
                  isValidPathSegment(segment)
            else {
                return nil
            }
            decodedSegments.append(segment)
        }
        return decodedSegments
    }

    private static func isValidPathSegment(_ segment: String) -> Bool {
        !segment.isEmpty
            && segment != "."
            && segment != ".."
            && !segment.contains("/")
            && !segment.contains("\\")
            && !segment.unicodeScalars.contains { $0.value == 0 }
    }

    /// `URLComponents` reports `https://github.com:/o/r` (bare port delimiter) as port == nil, so the
    /// port guard alone can't reject it: require the raw authority — everything between `://` and the
    /// first `/`, `?`, or `#` — to be exactly the bare host.
    private static func hasBareGitHubAuthority(_ trimmed: String) -> Bool {
        guard let schemeRange = trimmed.range(of: "://") else { return false }
        let authority = trimmed[schemeRange.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return authority.lowercased() == "github.com"
    }

    private static func isGitHubOwner(_ owner: String) -> Bool {
        guard let first = owner.first, let last = owner.last,
              first != "-", last != "-"
        else {
            return false
        }
        return owner.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func isGitHubRepository(_ repository: String) -> Bool {
        !repository.isEmpty
            && repository != "."
            && repository != ".."
            && repository.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
            }
    }

    private static func isPlausibleRef(_ ref: String) -> Bool {
        guard isValidPathSegment(ref),
              ref != "@",
              !ref.hasPrefix("."),
              !ref.hasSuffix("."),
              !ref.hasSuffix(".lock"),
              !ref.contains(".."),
              !ref.contains("@{")
        else {
            return false
        }

        let forbidden = CharacterSet(charactersIn: " ~^:?*[")
        return !ref.unicodeScalars.contains {
            $0.value < 32 || $0.value == 127 || forbidden.contains($0)
        }
    }

    private static func isCommitSHA(_ ref: String) -> Bool {
        ref.utf8.count == 40 && ref.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0)
        }
    }

    private static func reconstructedRemotes(
        owner: String,
        repository: String
    ) -> (repo: String, clone: String)? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\?#"))
        guard let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedRepository = repository.addingPercentEncoding(withAllowedCharacters: allowed)
        else {
            return nil
        }
        let repo = "https://github.com/\(encodedOwner)/\(encodedRepository)"
        return (repo, "\(repo).git")
    }
}

struct ValidatedInstallRemote: Equatable {
    let repo: String
    let cloneRemote: String
}

enum InstallRemotePolicy {
    typealias Validator = (String) -> ValidatedInstallRemote?

    /// Stored install coordinates are synced YAML and therefore untrusted. Only a repository-form
    /// GitHub URL may cross back into git, and git receives the reconstructed clone remote rather
    /// than the stored bytes.
    static func validateGitHubRepository(_ storedRemote: String) -> ValidatedInstallRemote? {
        guard let parsed = SkillInstallURL.parse(storedRemote), parsed.form == .repo else {
            return nil
        }
        return ValidatedInstallRemote(repo: parsed.repo, cloneRemote: parsed.cloneRemote)
    }
}
