import Foundation
import SwiftData

extension SkillInstallService {
    func install(candidate: SkillCandidate, from source: SkillFetchResult,
                 credential: GitCredential? = nil,
                 bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed,
                 context: ModelContext) throws -> SkillInstallResult {
        try install(
            candidate: candidate,
            slug: candidate.slug,
            from: source,
            credential: credential,
            bodyWriteRegistration: bodyWriteRegistration,
            context: context
        )
    }

    func install(candidate: SkillCandidate, renamedTo slug: String, from source: SkillFetchResult,
                 credential: GitCredential? = nil,
                 bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed,
                 context: ModelContext) throws -> SkillInstallResult {
        try install(
            candidate: candidate,
            slug: slug,
            from: source,
            credential: credential,
            bodyWriteRegistration: bodyWriteRegistration,
            context: context
        )
    }

    func adopt(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
               credential: GitCredential? = nil,
               context: ModelContext) throws -> SkillAdoptResult {
        let lock = try acquireMutationLock()
        defer { lock.release() }

        let existing = try requireExistingSkill(slug: existingSlug, context: context)
        let localDirectory = try safeExistingDirectory(slug: existingSlug)

        return try withVerifiedCheckout(
            candidate: candidate,
            source: source,
            credential: credential
        ) { checkout, verified in
            try requireInstallable(verified)
            let upstreamDirectory = candidateDirectory(candidate: verified, checkout: checkout)
            let upstreamHash = try stableContentHash(
                at: upstreamDirectory,
                excludingTopLevelGitMetadata: verified.path.isEmpty
            )
            let timestamp = now()
            let origin = makeOrigin(
                candidate: verified,
                source: source,
                contentHash: upstreamHash,
                installedAt: timestamp,
                updatedAt: timestamp
            )
            let snapshot = try readValidatedManifest()
            let overlay = mergedOverlay(
                slug: existingSlug,
                existing: existing,
                current: snapshot.skills.first { $0.slug == existingSlug },
                origin: origin
            )
            let localHash = try stableContentHash(at: localDirectory)

            try manifestService.upsertSkillOverlay(overlay, toRoot: storeRoot)
            do {
                existing.installedOrigin = origin
                existing.importedFrom = nil
                existing.resetUpdateCheckState()
                try context.save()
            } catch {
                throw SyncedStateMutationError(underlyingError: error)
            }
            return localHash == upstreamHash ? .clean : .localDrift
        }
    }

    func update(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                credential: GitCredential? = nil,
                bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed,
                context: ModelContext) throws {
        try updateVerified(
            existingSlug: existingSlug,
            candidate: candidate,
            from: source,
            credential: credential,
            beforeVendorSwap: nil,
            bodyWriteRegistration: bodyWriteRegistration,
            context: context
        )
    }

    func updateVerified(existingSlug: String, candidate: SkillCandidate,
                        from source: SkillFetchResult,
                        credential: GitCredential? = nil,
                        beforeVendorSwap: ((String) throws -> Void)?,
                        bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed,
                        context: ModelContext) throws {
        let lock = try acquireMutationLock()
        defer { lock.release() }

        let existing = try requireExistingSkill(slug: existingSlug, context: context)
        let previousOrigin = try existing.installedOrigin
            ?? { throw SkillInstallError.existingSkillNotFound(existingSlug) }()
        let destination = try safeExistingDirectory(slug: existingSlug)
        let snapshot = try readValidatedManifest()
        let currentOverlay = snapshot.skills.first { $0.slug == existingSlug }

        try withVerifiedCheckout(
            candidate: candidate,
            source: source,
            credential: credential
        ) { checkout, verified in
            try requireInstallable(verified)
            let sourceDirectory = candidateDirectory(candidate: verified, checkout: checkout)
            try vendorBody(
                sourceDirectory: sourceDirectory, destination: destination, slug: existingSlug,
                excludingTopLevelGitMetadata: verified.path.isEmpty,
                beforeReplace: { try beforeVendorSwap?(destination) },
                registration: bodyWriteRegistration
            )
            do {
                let contentHash = try stableContentHash(at: destination)
                let timestamp = now()
                let origin = makeOrigin(
                    candidate: verified,
                    source: source,
                    contentHash: contentHash,
                    installedAt: previousOrigin.installedAt,
                    updatedAt: timestamp
                )
                let overlay = mergedOverlay(
                    slug: existingSlug,
                    existing: existing,
                    current: currentOverlay,
                    origin: origin
                )

                try manifestService.upsertSkillOverlay(overlay, toRoot: storeRoot)
                existing.installedOrigin = origin
                existing.name = verified.name ?? existing.name
                existing.skillDescription = verified.skillDescription ?? existing.skillDescription
                existing.updatedAt = timestamp
                existing.resetUpdateCheckState()
                try context.save()
            } catch {
                throw SyncedStateMutationError(underlyingError: error)
            }
        }
    }
}

// MARK: - Install flow

extension SkillInstallService {
    private func install(candidate: SkillCandidate, slug: String, from source: SkillFetchResult,
                         credential: GitCredential?,
                         bodyWriteRegistration: SyncBodyWriteRegistration,
                         context: ModelContext) throws -> SkillInstallResult {
        try validateSlug(slug)
        try requireInstallable(candidate)
        let lock = try acquireMutationLock()
        defer { lock.release() }

        if let collision = try collision(for: slug, context: context) {
            return .collision(existing: collision)
        }
        _ = try readValidatedManifest()
        let skillsRoot = storeRoot + "/skills"
        if !fileService.directoryExists(at: skillsRoot) {
            try fileService.createDirectory(at: skillsRoot)
        }
        guard let destination = SkillStore.safeSkillDirectory(
            slug: slug,
            base: skillsRoot,
            fileService: fileService
        ) else {
            throw SkillInstallError.unsafeSkillDirectory(slug)
        }

        return try withVerifiedCheckout(
            candidate: candidate,
            source: source,
            credential: credential
        ) { checkout, verified in
            try requireInstallable(verified)
            let sourceDirectory = candidateDirectory(candidate: verified, checkout: checkout)
            try vendorBody(
                sourceDirectory: sourceDirectory, destination: destination, slug: slug,
                excludingTopLevelGitMetadata: verified.path.isEmpty,
                registration: bodyWriteRegistration
            )
            do {
                let contentHash = try stableContentHash(at: destination)
                try finishInstall(
                    verified: verified,
                    slug: slug,
                    source: source,
                    contentHash: contentHash,
                    context: context
                )
            } catch {
                throw SyncedStateMutationError(underlyingError: error)
            }
            return .installed(slug: slug)
        }
    }

    private func vendorBody(
        sourceDirectory: String,
        destination: String,
        slug: String,
        excludingTopLevelGitMetadata: Bool,
        beforeReplace: () throws -> Void = {},
        registration: SyncBodyWriteRegistration
    ) throws {
        let expectedBody = SkillParser.stripFrontmatter(
            try fileService.readFile(at: sourceDirectory + "/SKILL.md")
        )
        var bodyWriteBegan = false
        var bodyWriteSucceeded = false
        defer { if bodyWriteBegan { registration.end(slug, bodyWriteSucceeded) } }
        try vendor(sourceDirectory: sourceDirectory, to: destination,
                   excludingTopLevelGitMetadata: excludingTopLevelGitMetadata) {
            try beforeReplace()
            registration.begin(slug, expectedBody)
            bodyWriteBegan = true
        }
        bodyWriteSucceeded = true
    }

    private func finishInstall(verified: SkillCandidate, slug: String,
                               source: SkillFetchResult, contentHash: String,
                               context: ModelContext) throws {
        let timestamp = now()
        let origin = makeOrigin(
            candidate: verified,
            source: source,
            contentHash: contentHash,
            installedAt: timestamp,
            updatedAt: timestamp
        )
        let overlay = SkillOverlay(
            slug: slug,
            createdAt: timestamp,
            scope: .user,
            tags: [],
            cursor: nil,
            agents: [],
            origin: .installed(origin)
        )
        try manifestService.upsertSkillOverlay(overlay, toRoot: storeRoot)
        let skill = Skill(
            name: verified.name ?? slug,
            skillDescription: verified.skillDescription ?? verified.name ?? slug,
            scope: .user,
            directoryName: slug
        )
        skill.installedOrigin = origin
        skill.createdAt = timestamp
        skill.updatedAt = timestamp
        context.insert(skill)
        try context.save()
    }

    private func collision(for slug: String, context: ModelContext) throws -> SkillCollision? {
        let path = storeRoot + "/skills/" + slug
        let hasDirectory = fileService.directoryExists(at: path)
            || fileService.fileExists(at: path)
            || fileService.isSymlink(at: path)
        let wanted = slug.lowercased()
        let hasRow = try context.fetch(FetchDescriptor<Skill>())
            .contains { $0.directoryName.lowercased() == wanted }
        guard hasDirectory || hasRow else { return nil }
        return SkillCollision(slug: slug, hasDirectory: hasDirectory, hasSwiftDataRow: hasRow)
    }

    private func validateSlug(_ slug: String) throws {
        guard SkillStore.isCanonicalSlug(slug) else {
            throw SkillInstallError.invalidSlug(slug)
        }
    }

    func requireInstallable(_ candidate: SkillCandidate) throws {
        if let reason = candidate.unavailableReason {
            throw SkillInstallError.unavailableCandidate(reason)
        }
        guard candidate.isInstallable, candidate.name != nil,
              candidate.skillDescription != nil, !candidate.containsSymlink else {
            throw SkillInstallError.unavailableCandidate("skill is not installable")
        }
    }
}

// MARK: - Coordinates and existing overlay

extension SkillInstallService {
    private func acquireMutationLock() throws -> SyncLock {
        guard let lock = SyncLock.tryAcquire(at: lockPath) else {
            throw SkillInstallError.syncInProgress
        }
        return lock
    }

    private func candidateDirectory(candidate: SkillCandidate, checkout: String) -> String {
        candidate.path.isEmpty ? checkout : checkout + "/" + candidate.path
    }

    private func safeExistingDirectory(slug: String) throws -> String {
        guard let path = SkillStore.safeSkillDirectory(
            slug: slug,
            base: storeRoot + "/skills",
            fileService: fileService
        ), fileService.directoryExists(at: path) else {
            throw SkillInstallError.unsafeSkillDirectory(slug)
        }
        return path
    }

    private func requireExistingSkill(slug: String, context: ModelContext) throws -> Skill {
        guard let existing = try context.fetch(FetchDescriptor<Skill>())
            .first(where: { $0.directoryName == slug }) else {
            throw SkillInstallError.existingSkillNotFound(slug)
        }
        return existing
    }

    private func makeOrigin(candidate: SkillCandidate, source: SkillFetchResult,
                            contentHash: String, installedAt: Date,
                            updatedAt: Date) -> InstalledOrigin {
        InstalledOrigin(
            repo: source.repo,
            path: candidate.path,
            ref: source.ref,
            installedCommit: source.headCommit,
            installedTree: candidate.treeHash,
            contentHash: contentHash,
            installedAt: installedAt,
            updatedAt: updatedAt
        )
    }
    private func readValidatedManifest() throws -> ManifestSnapshot {
        let snapshot = try manifestService.read(fromRoot: storeRoot)
        try ManifestService.validateSkillSlugs(snapshot.skills)
        return snapshot
    }

    private func mergedOverlay(slug: String, existing: Skill,
                               current: SkillOverlay?,
                               origin: InstalledOrigin) -> SkillOverlay {
        return SkillOverlay(
            slug: slug,
            createdAt: current?.createdAt ?? existing.createdAt,
            scope: current?.scope ?? existing.scope,
            tags: current?.tags ?? existing.tags,
            cursor: current?.cursor ?? existing.cursorConfig,
            agents: current?.agents ?? [],
            origin: .installed(origin)
        )
    }
}
