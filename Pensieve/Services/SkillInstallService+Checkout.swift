import Foundation

extension SkillInstallService {
    func withVerifiedCheckout<Result>(
        candidate: SkillCandidate,
        source: SkillFetchResult,
        credential: GitCredential?,
        body: (String, SkillCandidate) throws -> Result
    ) throws -> Result {
        try withCheckout(source: source, credential: credential) { checkoutPath in
            let refreshed = try discover(at: checkoutPath, path: candidate.path)
            guard let verified = refreshed.first, verified.treeHash == candidate.treeHash,
                  verified.slug == candidate.slug else {
                throw SkillInstallError.repositoryChanged
            }
            return try body(checkoutPath, verified)
        }
    }

    /// The preview verifies coordinates without discovery's whole SKILL.md/frontmatter read.
    /// The unchanged install/apply path still performs its normal candidate admission above.
    func withPinnedCheckout<Result>(candidate: SkillCandidate, source: SkillFetchResult,
                                    credential: GitCredential?, body: (String) throws -> Result) throws -> Result {
        guard InstallRelativePathPolicy.isValid(candidate.path) else {
            throw SkillInstallError.invalidRepositoryPath(candidate.path)
        }
        return try withCheckout(source: source, credential: credential) { checkoutPath in
            var directory = checkoutPath
            for component in candidate.path.split(separator: "/") {
                directory += "/" + component
                guard try fileService.entryTypeWithoutFollowingLinks(at: directory) == .directory else {
                    throw SkillInstallError.unavailableCandidate("Unsafe upstream directory: \(directory)")
                }
            }
            guard try gitService.treeHash(at: checkoutPath, path: candidate.path) == candidate.treeHash else {
                throw SkillInstallError.repositoryChanged
            }
            return try body(checkoutPath)
        }
    }

    private func withCheckout<Result>(source: SkillFetchResult, credential: GitCredential?,
                                      body: (String) throws -> Result) throws -> Result {
        try prepareScratchRoot()
        let sessionRoot = scratchRoot + "/" + UUID().uuidString
        try fileService.createDirectory(at: sessionRoot)
        defer { try? fileService.deleteDirectory(at: sessionRoot) }

        guard let validatedRemote = validateRemote(source.repo) else {
            throw SkillInstallError.unsupportedRepositoryRemote
        }
        let checkoutName = SkillStore.slugify(repositoryName(for: validatedRemote.repo))
        let checkoutPath = sessionRoot + "/" + checkoutName
        try cloneForInstall(
            remote: validatedRemote.cloneRemote,
            branch: source.ref,
            into: checkoutPath,
            credential: credential
        )
        guard try gitService.commitSHA(at: checkoutPath) == source.headCommit else {
            throw SkillInstallError.repositoryChanged
        }
        return try body(checkoutPath)
    }
}
