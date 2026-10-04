import Foundation

// MARK: - Types

struct BrokenLink: Equatable {
    let linkPath: String
    let expectedTarget: String
    let actualTarget: String?
}

// MARK: - Protocol

protocol LinkServiceProtocol {
    /// Create symlink: platform path → ~/.pensieve/skills/{name}/
    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws
    /// Remove symlink
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws
    /// Check if symlink exists and points to correct target
    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool
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

    init(fileService: FileServiceProtocol) {
        self.fileService = fileService
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

        let link = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        let target = targetPath(skill: skill, platform: platform, projectPath: projectPath)

        // Verify the target exists
        guard fileService.directoryExists(at: Constants.pensieveSkillsDir + "/" + skill.directoryName) else {
            throw LinkError.targetDoesNotExist(target)
        }

        if !fileService.isSymlink(at: link),
           fileService.fileExists(at: link) || fileService.directoryExists(at: link) {
            throw LinkError.occupiedByRealPath(link)
        }

        if let projectPath {
            try fileService.writeInProject(at: link, projectPath: projectPath) {
                try fileService.createSymlinkWithoutParents(at: link, pointingTo: target)
            }
        } else {
            try fileService.createSymlink(at: link, pointingTo: target)
        }
    }

    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        // Path-component safety invariant at the remove boundary too (mirrors link()):
        // a malicious directoryName must not let a delete escape the intended deploy root.
        try Self.validatePathComponent(skill.directoryName)
        if platform == .hermes {
            try Self.validatePathComponent(Constants.hermesDefaultCategory)
        }

        let link = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        guard fileService.isSymlink(at: link) else { return }
        try fileService.deleteFile(at: link)
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        let link = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        guard fileService.isSymlink(at: link) else { return false }
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
