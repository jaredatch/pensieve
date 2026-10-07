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
        return try withCheckout(source: source, credential: credential, preview: true) { checkoutPath in
            var directory = checkoutPath
            var relative = ""
            for component in candidate.path.split(separator: "/") {
                directory += "/" + component
                relative += (relative.isEmpty ? "" : "/") + component
                guard try fileService.entryTypeWithoutFollowingLinks(at: directory) == .directory else {
                    throw SkillInstallError.unavailableCandidate("Unsafe upstream directory: \(relative)")
                }
            }
            let tree = try previewOperation(.treeHash) { try gitService.treeHash(at: checkoutPath, path: candidate.path) }
            guard tree == candidate.treeHash else {
                throw SkillInstallError.repositoryChanged
            }
            return try body(checkoutPath)
        }
    }

    /// Checks required nonempty name/description frontmatter and UTF-8 in the bounded prefix.
    /// Oversized bodies are not validated beyond that prefix; apply still validates the whole file.
    func requirePreviewInstallable(_ candidate: SkillCandidate, at path: String) throws -> Int {
        let maximum = FileTreeComparisonLimits.updatePreview.maximumFileBytes
        let bounded = try fileService.readRegularFilePrefix(at: path, maximumBytes: maximum)
        let prefix = bounded.count > maximum
        let data = prefix ? bounded.prefix(maximum) : bounded
        var text = String(data: data, encoding: .utf8)
        // A prefix may end in the middle of a UTF-8 scalar; a complete file must never be repaired.
        if prefix && text == nil {
            for omitted in 1...min(3, data.count) where text == nil {
                text = String(data: data.dropLast(omitted), encoding: .utf8)
            }
        }
        guard let text else { throw SkillInstallError.unavailableCandidate(Self.invalidFrontmatterReason) }
        let parsed = SkillParser.parse(text)
        try requireInstallable(SkillCandidate(
            path: candidate.path, slug: candidate.slug, name: parsed.name, skillDescription: parsed.description,
            treeHash: candidate.treeHash, containsSymlink: false,
            unavailableReason: parsed.hasRequiredFrontmatter ? nil : Self.invalidFrontmatterReason
        ))
        return bounded.count
    }

    private func withCheckout<Result>(source: SkillFetchResult, credential: GitCredential?, preview: Bool = false,
                                      body: (String) throws -> Result) throws -> Result {
        try previewOperation(.prepare, enabled: preview) { try prepareScratchRoot() }
        let sessionRoot = scratchRoot + "/" + UUID().uuidString
        try previewOperation(.prepare, enabled: preview) { try fileService.createDirectory(at: sessionRoot) }
        defer { try? fileService.deleteDirectory(at: sessionRoot) }

        guard let validatedRemote = validateRemote(source.repo) else {
            throw SkillInstallError.unsupportedRepositoryRemote
        }
        let checkoutName = SkillStore.slugify(repositoryName(for: validatedRemote.repo))
        let checkoutPath = sessionRoot + "/" + checkoutName
        try previewOperation(.fetch, enabled: preview) {
            try cloneForInstall(remote: validatedRemote.cloneRemote, branch: source.ref,
                                into: checkoutPath, credential: credential)
        }
        let commit = try previewOperation(.pinnedCommit, enabled: preview) { try gitService.commitSHA(at: checkoutPath) }
        guard commit == source.headCommit else {
            throw SkillInstallError.repositoryChanged
        }
        return try body(checkoutPath)
    }

    private func previewOperation<Result>(_ operation: PreviewOperation, enabled: Bool = true,
                                          body: () throws -> Result) throws -> Result {
        do { return try body() } catch {
            guard enabled else { throw error }
            if error is CancellationError { throw error }
            let classified = Self.mappedRepositoryError(error)
            if case GitError.unusable = classified {
                throw SkillUpdateFlowError.previewReadFailed(classified.localizedDescription)
            }
            if let failure = classified as? SkillInstallError {
                switch failure {
                case .authenticationFailed, .networkUnavailable, .repositoryNotFound, .repositoryChanged:
                    throw failure
                default: break
                }
            }
            throw SkillUpdateFlowError.previewReadFailed(operation.rawValue)
        }
    }

    private enum PreviewOperation: String {
        case prepare = "Couldn't prepare the upstream preview."
        case fetch = "Couldn't fetch the upstream repository."
        case pinnedCommit = "Couldn't verify the pinned commit."
        case treeHash = "Couldn't check the upstream tree hash."
    }

}
