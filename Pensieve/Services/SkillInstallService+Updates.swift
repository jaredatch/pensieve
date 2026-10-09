import Darwin
import Foundation
import SwiftData

struct PinnedSkillUpdate: Equatable {
    let skillID: UUID
    let existingSlug: String
    let installedContentHash: String
    let candidate: SkillCandidate
    let source: SkillFetchResult

    init(skill: Skill) throws {
        guard skill.hasLinkedOrigin, let origin = skill.installedOrigin,
              let upstreamCommit = skill.upstreamCommit, !upstreamCommit.isEmpty,
              let upstreamTree = skill.upstreamTree, !upstreamTree.isEmpty else {
            throw SkillUpdateFlowError.missingPinnedUpdate
        }
        let candidateSlug: String
        if origin.path.isEmpty {
            let repository = origin.repo.hasSuffix("/")
                ? String(origin.repo.dropLast())
                : origin.repo
            let component = (repository as NSString).lastPathComponent
            candidateSlug = SkillStore.slugify(
                component.hasSuffix(".git") ? String(component.dropLast(4)) : component
            )
        } else {
            candidateSlug = SkillStore.slugify((origin.path as NSString).lastPathComponent)
        }
        let candidate = SkillCandidate(
            path: origin.path,
            slug: candidateSlug,
            name: skill.name,
            skillDescription: skill.skillDescription,
            treeHash: upstreamTree,
            containsSymlink: false,
            unavailableReason: nil
        )
        self.skillID = skill.id
        self.existingSlug = skill.directoryName
        self.installedContentHash = origin.contentHash
        self.candidate = candidate
        self.source = SkillFetchResult(
            repo: origin.repo,
            ref: origin.ref,
            headCommit: upstreamCommit,
            candidates: [candidate]
        )
    }
}

enum SkillUpdateFlowError: LocalizedError, Equatable {
    static let repositoryChangedMessage =
        "Repository changed since last check — re-check to review the latest version"

    case missingPinnedUpdate
    case repositoryChanged
    case localEditsRequireConfirmation
    case skillNotFound
    case unsafeSkillDirectory(String)
    case unsafeSkillFile(String)
    case previewReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPinnedUpdate:
            "This update is no longer pinned — re-check to review the latest version"
        case .repositoryChanged:
            Self.repositoryChangedMessage
        case .localEditsRequireConfirmation:
            "This skill has local edits — updating will overwrite them"
        case .skillNotFound:
            "The skill is no longer available"
        case let .unsafeSkillDirectory(slug):
            "The local skill directory is unsafe: \(slug)"
        case let .previewReadFailed(message):
            message
        case let .unsafeSkillFile(slug):
            "The skill file is unsafe: \(slug)/SKILL.md"
        }
    }
}

extension SkillInstallService {
    /// Reads both diff sides only after the fresh checkout matches the pinned commit and tree.
    /// The operation writes scratch clone data only; it never touches the store, manifest, or flags.
    func previewUpdate(_ update: PinnedSkillUpdate) throws -> PinnedSkillDiff {
        var upstreamRoot: String?
        do {
            return try withPinnedCheckout(
                candidate: update.candidate,
                source: update.source,
                credential: nil
            ) { checkout in
                guard let localDirectory = SkillStore.safeSkillDirectory(
                    slug: update.existingSlug,
                    base: storeRoot + "/skills",
                    fileService: fileService
                ), fileService.directoryExists(at: localDirectory) else {
                    throw SkillUpdateFlowError.unsafeSkillDirectory(update.existingSlug)
                }
                let upstreamDirectory = update.candidate.path.isEmpty
                    ? checkout
                    : checkout + "/" + update.candidate.path
                upstreamRoot = upstreamDirectory
                guard fileService.isRegularFile(at: localDirectory + "/SKILL.md") else {
                    throw SkillUpdateFlowError.unsafeSkillFile(update.existingSlug)
                }
                guard fileService.isRegularFile(at: upstreamDirectory + "/SKILL.md") else {
                    throw SkillInstallError.unavailableCandidate("Unsafe upstream file: SKILL.md")
                }
                let comparison = try fileService.compareFileTrees(
                    local: localDirectory, upstream: upstreamDirectory,
                    excludingUpstreamGit: update.candidate.path.isEmpty, limits: .updatePreview,
                    beforeReading: {
                        try requirePreviewInstallable(update.candidate, at: upstreamDirectory + "/SKILL.md")
                    }
                )
                return try PinnedSkillDiff.build(comparison: comparison)
            }
        } catch {
            if error as? SkillInstallError == .repositoryChanged { throw SkillUpdateFlowError.repositoryChanged }
            throw previewReadError(error, local: storeRoot + "/skills/" + update.existingSlug,
                                   upstream: upstreamRoot ?? scratchRoot,
                                   skillPath: upstreamRoot == nil ? update.candidate.path : nil)
        }
    }

    private func previewReadError(_ error: Error, local: String, upstream: String, skillPath: String? = nil) -> Error {
        let failure = error as NSError
        guard let path = failure.userInfo[NSFilePathErrorKey] as? String else {
            if error is CancellationError || error is SkillInstallError || error is SkillUpdateFlowError
                || error is FileTreeComparisonError { return error }
            return SkillUpdateFlowError.previewReadFailed("Couldn't compare the skill's files.")
        }
        let isUpstream = PathSyntax.isWithin(path, root: upstream)
        let root = isUpstream ? upstream : local
        guard PathSyntax.isWithin(path, root: root) else {
            return SkillUpdateFlowError.previewReadFailed("Couldn't compare the skill's files.")
        }
        var relative = PathSyntax.relativePath(path, under: root).flatMap { $0.isEmpty ? nil : $0 } ?? "."
        if isUpstream, let skillPath {
            // Scratch/session/repository are implementation paths, not part of the skill.
            let components = PathSyntax.components(relative)
            relative = components.count > 2 ? components.dropFirst(2).joined(separator: "/") : "."
            if !skillPath.isEmpty {
                if PathSyntax.isWithin(skillPath, root: relative) {
                    relative = "."
                } else if PathSyntax.isWithin(relative, root: skillPath, includingRoot: false) {
                    relative = PathSyntax.relativePath(relative, under: skillPath) ?? "."
                }
            }
        }
        let reason = previewReadReason(failure)
        let message = "Cannot preview \(isUpstream ? "upstream" : "local") path \(relative): \(reason)."
        return isUpstream ? SkillInstallError.unavailableCandidate(message) : SkillUpdateFlowError.previewReadFailed(message)
    }

    private func previewReadReason(_ failure: NSError) -> String {
        switch (failure.domain, failure.code) {
        case (NSPOSIXErrorDomain, Int(ELOOP)), (NSPOSIXErrorDomain, Int(EFTYPE)):
            return "symbolic links and special files cannot be previewed"
        case (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)),
             (NSCocoaErrorDomain, CocoaError.Code.fileReadNoPermission.rawValue):
            return "permission denied"
        case (NSPOSIXErrorDomain, Int(ENOENT)), (NSPOSIXErrorDomain, Int(ENOTDIR)),
             (NSCocoaErrorDomain, CocoaError.Code.fileNoSuchFile.rawValue),
             (NSCocoaErrorDomain, CocoaError.Code.fileReadNoSuchFile.rawValue):
            return "the file or folder is no longer available"
        case (NSPOSIXErrorDomain, Int(ESTALE)): return "the folder changed while being read"
        case (NSCocoaErrorDomain, CocoaError.Code.fileReadCorruptFile.rawValue): return "the file is damaged"
        case (NSCocoaErrorDomain, CocoaError.Code.fileReadTooLarge.rawValue): return "the file is too large to read"
        default: return "the file or folder could not be read"
        }
    }

    func applyUpdate(_ update: PinnedSkillUpdate, allowLocalOverwrite: Bool,
                     bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed,
                     context: ModelContext) throws {
        do {
            try updateVerified(
                existingSlug: update.existingSlug,
                candidate: update.candidate,
                from: update.source,
                credential: nil,
                beforeVendorSwap: { destination in
                    guard !allowLocalOverwrite else { return }
                    let currentHash = try stableContentHash(at: destination)
                    guard currentHash == update.installedContentHash else {
                        throw SkillUpdateFlowError.localEditsRequireConfirmation
                    }
                },
                bodyWriteRegistration: bodyWriteRegistration,
                context: context
            )
        } catch SkillInstallError.repositoryChanged {
            throw SkillUpdateFlowError.repositoryChanged
        }
    }
}
