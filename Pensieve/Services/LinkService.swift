import Foundation

// MARK: - Types

struct BrokenLink: Equatable {
    let linkPath: String
    let expectedTarget: String
    let actualTarget: String?
}

// MARK: - Protocol

protocol LinkServiceProtocol: DeployRemovalPreparing {
    /// Create symlink: platform path → ~/.pensieve/skills/{name}/
    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws
    /// Remove an owned link; true only after deleting it from disk.
    @discardableResult
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool
    /// Check if symlink exists and points to correct target
    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool
    /// Get the link path for a skill on a platform
    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String
    /// Get the target path that the symlink should point to
    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String
    /// Validate all symlinks (find broken ones)
    func validateAll(skills: [Skill]) -> [BrokenLink]
}

// MARK: - Implementation

final class LinkService: LinkServiceProtocol {
    private let fileService: FileServiceProtocol
    private let ownership: DeployArtifactOwnershipChecking

    init(fileService: FileServiceProtocol) {
        self.fileService = fileService
        self.ownership = DeployArtifactOwnership(fileService: fileService)
    }

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        guard platform.usesSymlinks else {
            throw LinkError.platformDoesNotUseSymlinks(platform)
        }

        if projectPath != nil, !platform.supportsProjectScope {
            throw LinkError.projectScopeUnsupported(platform)
        }

        // Path-component safety invariant, enforced at the deploy boundary before any symlink.
        try Self.validatePathComponent(skill.directoryName)
        // Hermes nests under a category path component; validate it too (PLAN-05 makes it user-influenced).
        if platform == .hermes {
            try Self.validatePathComponent(Constants.hermesDefaultCategory)
        }

        let projectDirectory = try projectPath.map { try fileService.requireProjectDirectory(at: $0) }

        let link = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        let target = targetPath(skill: skill, platform: platform, projectPath: projectPath)

        // Verify the target exists
        guard fileService.directoryExists(at: Constants.pensieveSkillsDir + "/" + skill.directoryName) else {
            throw LinkError.targetDoesNotExist(target)
        }

        let occupant = try ownership.link(
            at: link, skillsDirectory: Constants.pensieveSkillsDir, linksFile: platform == .codex && projectPath != nil
        )
        if occupant == .foreignLink { throw ArtifactOwnershipError.occupiedPath(link) }
        if occupant == .foreign { throw LinkError.occupiedByRealPath(link) }

        do {
            if let projectDirectory {
                try fileService.createSymlinkInProject(at: link, pointingTo: target, project: projectDirectory)
            } else {
                try fileService.createSymlink(at: link, pointingTo: target)
            }
        } catch SymlinkCreationError.occupiedPath(_) {
            throw LinkError.occupiedByRealPath(link)
        }
    }

    @discardableResult
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        try DeployRemovalService.removeArtifact(removalOperation(skill: skill, platform: platform, projectPath: projectPath))
    }

    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        try artifactOccupant(skill: skill, platform: platform, projectPath: projectPath).isOwned
    }

    private func artifactOccupant(skill: Skill, platform: PlatformTarget,
                                  projectPath: String?) throws -> DeployArtifactOccupant {
        guard platform.usesSymlinks, projectPath == nil || platform.supportsProjectScope else { return .foreign }
        try Self.validatePathComponent(skill.directoryName)
        if platform == .hermes { try Self.validatePathComponent(Constants.hermesDefaultCategory) }
        guard ProjectDirectory.canAccess(projectPath) else { return .foreign }
        return try ownership.link(
            at: linkPath(skill: skill, platform: platform, projectPath: projectPath),
            skillsDirectory: Constants.pensieveSkillsDir, linksFile: platform == .codex && projectPath != nil
        )
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        guard projectPath == nil || platform.supportsProjectScope else { return false }
        guard ProjectDirectory.canAccess(projectPath) else { return false }
        let link = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        guard platform.usesSymlinks, fileService.isSymlink(at: link) else { return false }
        let expected = targetPath(skill: skill, platform: platform, projectPath: projectPath)
        guard let actual = try? fileService.symlinkTarget(at: link) else { return false }
        return actual == expected
    }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        DeployPaths.linkPath(directoryName: skill.directoryName, platform: platform, projectPath: projectPath)
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        DeployPaths.targetPath(directoryName: skill.directoryName, platform: platform, projectPath: projectPath)
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] {
        var broken: [BrokenLink] = []

        for skill in skills {
            for platform in PlatformTarget.allCases where platform.usesSymlinks {
                // Check user-wide links
                let link = linkPath(skill: skill, platform: platform, projectPath: nil)
                if fileService.isSymlink(at: link) {
                    let expected = targetPath(skill: skill, platform: platform, projectPath: nil)
                    let actual = try? fileService.symlinkTarget(at: link)
                    if actual != expected {
                        broken.append(BrokenLink(
                            linkPath: link,
                            expectedTarget: expected,
                            actualTarget: actual
                        ))
                    }
                }
            }
        }

        return broken
    }

    /// Rejects a path component that could escape the intended skill root.
    /// Pure (no filesystem) so it is unit-testable hermetically; enforced in `link()`.
    static func validatePathComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.hasPrefix("~") else {
            throw LinkError.invalidPathComponent(component)
        }
    }
}

// MARK: - Errors

enum LinkError: LocalizedError {
    case platformDoesNotUseSymlinks(PlatformTarget)
    case targetDoesNotExist(String)
    case projectScopeUnsupported(PlatformTarget)
    case invalidPathComponent(String)
    case occupiedByRealPath(String)

    var errorDescription: String? {
        switch self {
        case .platformDoesNotUseSymlinks(let p):
            "\(p.displayName) uses compiled output, not symlinks. Use CursorCompiler instead."
        case .targetDoesNotExist(let path):
            "Skill directory does not exist at \(path)"
        case .projectScopeUnsupported(let p):
            "\(p.displayName) does not support project-scoped deploy yet."
        case .invalidPathComponent(let c):
            "Invalid skill path component: \(c)"
        case .occupiedByRealPath(let path):
            "A real file or directory already exists at \(path). "
                + "Pensieve will not overwrite it — move or delete it, then deploy again."
        }
    }
}

extension LinkService {
    func removalOperation(skill: Skill, platform: PlatformTarget, projectPath: String?) -> DeployRemovalOperation {
        let path = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        return DeployRemovalOperation(fileService: fileService, path: path) {
            return try self.artifactOccupant(skill: skill, platform: platform, projectPath: projectPath)
        }
    }
}
