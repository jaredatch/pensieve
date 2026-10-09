import Foundation
import SwiftData

struct SkillCandidate: Equatable {
    let path: String
    let slug: String
    let name: String?
    let skillDescription: String?
    let treeHash: String
    let containsSymlink: Bool
    let unavailableReason: String?

    var isInstallable: Bool {
        unavailableReason == nil
    }
}

struct SkillFetchResult: Equatable {
    let repo: String
    let ref: String
    let headCommit: String
    let candidates: [SkillCandidate]
}

enum SkillInstallError: LocalizedError, Equatable {
    case authenticationFailed
    case repositoryNotFound
    case networkUnavailable
    case invalidRepositoryPath(String)
    case noSkillMarkdown(path: String)
    case unavailableCandidate(String)
    case invalidSlug(String)
    case unsafeSkillDirectory(String)
    case repositoryChanged
    case existingSkillNotFound(String)
    case syncInProgress
    case unsupportedFileType(String)
    case unsupportedRepositoryRemote

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Authentication failed — for private repositories add a GitHub token in Settings"
        case .repositoryNotFound:
            // GitHub answers 404 for private repositories it hides from anonymous or under-scoped
            // callers (anti-enumeration), so a definitive "not found" would falsely deny private
            // repos exist — the surface must stay authentication-ambiguous.
            return "Repository not found — if it's private, make sure your GitHub token in Settings has access to it"
        case .networkUnavailable:
            return "Couldn't reach GitHub — check your internet connection and try again"
        case let .invalidRepositoryPath(path):
            return "invalid repository path: \(path)"
        case let .noSkillMarkdown(path):
            return "no SKILL.md at \(path)"
        case let .unavailableCandidate(reason):
            return reason
        case let .invalidSlug(slug):
            return "invalid skill slug: \(slug)"
        case let .unsafeSkillDirectory(slug):
            return "unsafe skill directory: \(slug)"
        case .repositoryChanged:
            return "the repository changed after discovery; fetch it again before installing"
        case let .existingSkillNotFound(slug):
            return "existing skill not found: \(slug)"
        case .syncInProgress:
            return "sync is already in progress"
        case let .unsupportedFileType(path):
            return "skill contains a symlink or non-regular entry: \(path)"
        case .unsupportedRepositoryRemote:
            return "stored repository is not a supported GitHub URL"
        }
    }
}

struct SkillCollision: Equatable {
    let slug: String
    let hasDirectory: Bool
    let hasSwiftDataRow: Bool
}

enum SkillInstallResult: Equatable {
    case installed(slug: String)
    case collision(existing: SkillCollision)
}

enum SkillAdoptResult: Equatable {
    case clean
    case localDrift
}

protocol SkillInstallGitServing {
    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?) throws
    func commitSHA(at path: String) throws -> String
    func currentBranch(at path: String) throws -> String
    func treeHash(at repositoryPath: String, path: String) throws -> String
}

extension GitService: SkillInstallGitServing {}

protocol SkillInstallServiceProtocol {
    func fetch(repo: String, ref: String?, credential: GitCredential?) throws -> SkillFetchResult
    func fetch(repo: String, ref: String?, path: String,
               credential: GitCredential?) throws -> SkillFetchResult
    func install(candidate: SkillCandidate, from source: SkillFetchResult,
                 credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                 context: ModelContext) throws -> SkillInstallResult
    func install(candidate: SkillCandidate, renamedTo slug: String, from source: SkillFetchResult,
                 credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                 context: ModelContext) throws -> SkillInstallResult
    func adopt(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
               credential: GitCredential?, context: ModelContext) throws -> SkillAdoptResult
    func update(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                context: ModelContext) throws
}

struct SkillInstallService: SkillInstallServiceProtocol, ScratchRootCleaning {
    static let invalidFrontmatterReason =
        "SKILL.md needs parseable frontmatter with non-empty name and description"
    private static let symlinkReason = "skill contains a symbolic link"

    let gitService: SkillInstallGitServing
    let credentialStore: CredentialStoreProtocol
    let fileService: FileServiceProtocol
    let scratchRoot: String
    let storeRoot: String
    let manifestService: ManifestReadWriting
    let lockPath: String
    let now: () -> Date
    let validateRemote: InstallRemotePolicy.Validator

    init(gitService: SkillInstallGitServing,
         credentialStore: CredentialStoreProtocol,
         fileService: FileServiceProtocol = FileService(),
         scratchRoot: String,
         storeRoot: String,
         manifestService: ManifestReadWriting? = nil,
         lockPath: String,
         now: @escaping () -> Date = Date.init,
         remoteValidator: @escaping InstallRemotePolicy.Validator =
             InstallRemotePolicy.validateGitHubRepository) {
        self.gitService = gitService
        self.credentialStore = credentialStore
        self.fileService = fileService
        self.scratchRoot = scratchRoot
        self.storeRoot = storeRoot
        self.manifestService = manifestService ?? ManifestService(fileService: fileService)
        self.lockPath = lockPath
        self.now = now
        self.validateRemote = remoteValidator
    }

    func fetch(repo: String, ref: String?, credential: GitCredential?) throws -> SkillFetchResult {
        try fetch(repo: repo, ref: ref, targetPath: nil, credential: credential)
    }

    func fetch(repo: String, ref: String?, path: String,
               credential: GitCredential?) throws -> SkillFetchResult {
        try fetch(repo: repo, ref: ref, targetPath: path, credential: credential)
    }

    func discover(at repositoryPath: String) throws -> [SkillCandidate] {
        var candidatePaths: Set<String> = []
        if skillFileIsPresent(at: repositoryPath + "/SKILL.md") {
            candidatePaths.insert("")
        }
        try collectSkillsDirectoryCandidates(at: repositoryPath, into: &candidatePaths)
        try collectClaudeCandidates(at: repositoryPath, into: &candidatePaths)
        return try candidatePaths.sorted().map {
            try makeCandidate(at: repositoryPath, relativePath: $0)
        }
    }

    func discover(at repositoryPath: String, path: String) throws -> [SkillCandidate] {
        guard InstallRelativePathPolicy.isValid(path) else {
            throw SkillInstallError.invalidRepositoryPath(path)
        }
        guard !hasSymlinkedComponent(at: repositoryPath, relativePath: path) else {
            throw SkillInstallError.noSkillMarkdown(path: path)
        }
        let directory = path.isEmpty ? repositoryPath : repositoryPath + "/" + path
        guard !fileService.isSymlink(at: directory),
              fileService.directoryExists(at: directory),
              skillFileIsPresent(at: directory + "/SKILL.md") else {
            throw SkillInstallError.noSkillMarkdown(path: path)
        }
        return [try makeCandidate(at: repositoryPath, relativePath: path)]
    }
}

extension SkillInstallService {
    private func fetch(repo: String, ref: String?, targetPath: String?,
                       credential: GitCredential?) throws -> SkillFetchResult {
        guard let validatedRemote = validateRemote(repo) else {
            throw SkillInstallError.unsupportedRepositoryRemote
        }
        try prepareScratchRoot()
        let sessionRoot = scratchRoot + "/" + UUID().uuidString
        try fileService.createDirectory(at: sessionRoot)
        defer { try? fileService.deleteDirectory(at: sessionRoot) }

        let checkoutName = SkillStore.slugify(repositoryName(for: validatedRemote.repo))
        let checkoutPath = sessionRoot + "/" + checkoutName
        try cloneForInstall(
            remote: validatedRemote.cloneRemote,
            branch: ref,
            into: checkoutPath,
            credential: credential
        )

        let headCommit = try gitService.commitSHA(at: checkoutPath)
        let resolvedRef = try ref ?? gitService.currentBranch(at: checkoutPath)
        let candidates: [SkillCandidate]
        if let targetPath {
            candidates = try discover(at: checkoutPath, path: targetPath)
        } else {
            candidates = try discover(at: checkoutPath)
        }
        return SkillFetchResult(
            repo: validatedRemote.repo,
            ref: resolvedRef,
            headCommit: headCommit,
            candidates: candidates
        )
    }

    func prepareScratchRoot() throws {
        if fileService.isSymlink(at: scratchRoot) {
            try fileService.deleteDirectory(at: scratchRoot)
        } else if fileService.fileExists(at: scratchRoot) {
            try fileService.deleteFile(at: scratchRoot)
        }
        if !fileService.directoryExists(at: scratchRoot) {
            try fileService.createDirectory(at: scratchRoot)
        }
    }

    private func collectSkillsDirectoryCandidates(
        at repositoryPath: String,
        into paths: inout Set<String>
    ) throws {
        let skillsPath = repositoryPath + "/skills"
        guard let firstLevel = try traversableEntries(at: skillsPath) else { return }
        for firstName in firstLevel where !firstName.hasPrefix(".") {
            let relative = "skills/" + firstName
            let firstPath = repositoryPath + "/" + relative
            if fileService.isSymlink(at: firstPath) {
                paths.insert(relative)
                continue
            }
            guard fileService.directoryExists(at: firstPath) else { continue }
            if skillFileIsPresent(at: firstPath + "/SKILL.md") {
                paths.insert(relative)
                continue
            }
            guard let secondLevel = try traversableEntries(at: firstPath) else { continue }
            for secondName in secondLevel where !secondName.hasPrefix(".") {
                let nestedRelative = relative + "/" + secondName
                let nestedPath = repositoryPath + "/" + nestedRelative
                if fileService.isSymlink(at: nestedPath) {
                    paths.insert(nestedRelative)
                } else if fileService.directoryExists(at: nestedPath),
                          skillFileIsPresent(at: nestedPath + "/SKILL.md") {
                    paths.insert(nestedRelative)
                }
            }
        }
    }

    private func collectClaudeCandidates(at repositoryPath: String,
                                         into paths: inout Set<String>) throws {
        let claudePath = repositoryPath + "/.claude"
        guard !fileService.isSymlink(at: claudePath) else { return }
        let skillsPath = claudePath + "/skills"
        guard let entries = try traversableEntries(at: skillsPath) else { return }
        for name in entries where !name.hasPrefix(".") {
            let relative = ".claude/skills/" + name
            let path = repositoryPath + "/" + relative
            if fileService.isSymlink(at: path) {
                paths.insert(relative)
            } else if fileService.directoryExists(at: path),
                      skillFileIsPresent(at: path + "/SKILL.md") {
                paths.insert(relative)
            }
        }
    }

    private func traversableEntries(at path: String) throws -> [String]? {
        guard !fileService.isSymlink(at: path), fileService.directoryExists(at: path) else {
            return nil
        }
        return try fileService.listDirectory(at: path).sorted()
    }

    private func makeCandidate(at repositoryPath: String,
                               relativePath: String) throws -> SkillCandidate {
        let directory = relativePath.isEmpty ? repositoryPath : repositoryPath + "/" + relativePath
        let containsSymlink = try subtreeContainsSymlink(
            at: directory,
            repositoryRoot: repositoryPath
        )
        let parsed = fileService.isSymlink(at: directory)
            ? nil
            : parsedFrontmatter(at: directory + "/SKILL.md")
        let unavailableReason: String?
        if containsSymlink {
            unavailableReason = Self.symlinkReason
        } else if parsed?.hasRequiredFrontmatter != true {
            unavailableReason = Self.invalidFrontmatterReason
        } else {
            unavailableReason = nil
        }
        let directoryName = relativePath.isEmpty
            ? repositoryName(for: repositoryPath)
            : (relativePath as NSString).lastPathComponent
        return SkillCandidate(
            path: relativePath,
            slug: SkillStore.slugify(directoryName),
            name: parsed?.name,
            skillDescription: parsed?.description,
            treeHash: try gitService.treeHash(at: repositoryPath, path: relativePath),
            containsSymlink: containsSymlink,
            unavailableReason: unavailableReason
        )
    }

    private func parsedFrontmatter(at skillFile: String) -> ParsedSkill? {
        guard fileService.isRegularFile(at: skillFile),
              let content = try? fileService.readFile(at: skillFile) else {
            return nil
        }
        return SkillParser.parse(content)
    }

    private func skillFileIsPresent(at path: String) -> Bool {
        fileService.isRegularFile(at: path) || fileService.isSymlink(at: path)
    }

    private func subtreeContainsSymlink(at directory: String, repositoryRoot: String) throws -> Bool {
        if fileService.isSymlink(at: directory) { return true }
        guard fileService.directoryExists(at: directory) else { return false }
        for entry in try fileService.listDirectory(at: directory) {
            if directory == repositoryRoot, entry == ".git" { continue }
            let path = directory + "/" + entry
            if fileService.isSymlink(at: path) { return true }
            if fileService.directoryExists(at: path),
               try subtreeContainsSymlink(at: path, repositoryRoot: repositoryRoot) {
                return true
            }
        }
        return false
    }

    private func hasSymlinkedComponent(at repositoryPath: String, relativePath: String) -> Bool {
        var path = repositoryPath
        for component in PathSyntax.components(relativePath, omittingEmptySubsequences: false) {
            path += "/" + component
            if fileService.isSymlink(at: path) { return true }
        }
        return false
    }

    func repositoryName(for value: String) -> String {
        let trimmed = value.hasSuffix("/") ? String(value.dropLast()) : value
        let lastComponent: String
        if let url = URL(string: trimmed), url.scheme != nil {
            lastComponent = url.lastPathComponent
        } else {
            lastComponent = (trimmed as NSString).lastPathComponent
        }
        let withoutGit = lastComponent.hasSuffix(".git")
            ? String(lastComponent.dropLast(".git".count))
            : lastComponent
        return withoutGit.isEmpty ? "repository" : withoutGit
    }
}
