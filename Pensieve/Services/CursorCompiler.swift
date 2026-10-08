import Foundation
import CryptoKit

// MARK: - Protocol

protocol CursorCompilerProtocol: DeployRemovalPreparing {
    /// Generate and write .mdc file from skill + Cursor config
    func compile(skill: Skill, projectPath: String?) throws
    /// Remove an owned rule; true only after deleting it from disk.
    @discardableResult
    func remove(skill: Skill, projectPath: String?) throws -> Bool
    /// Check if .mdc is up to date (content hash comparison)
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool
    /// Metadata only. Call ruleMayExist for shared slug and scope admission.
    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool
    /// Convergence upgrades owned legacy output before its source can change.
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool
    /// Get the output path for a compiled .mdc file
    func outputPath(skill: Skill, projectPath: String?) -> String
    /// Legacy ownership evidence retained before the source skill can disappear.
    func removalFingerprint(skill: Skill) -> CursorRemovalFingerprint?
}

extension CursorCompilerProtocol {
    func removalFingerprint(skill: Skill) -> CursorRemovalFingerprint? { nil }
    /// Validate before scope admission or filesystem access, for every compiler implementation.
    func ruleMayExist(skill: Skill, projectPath: String?) throws -> Bool {
        try LinkService.validatePathComponent(skill.directoryName)
        guard ProjectDirectory.canAccess(projectPath) else { return false }
        return try probeRulePresence(skill: skill, projectPath: projectPath)
    }
}

// MARK: - Implementation

final class CursorCompiler: CursorCompilerProtocol {
    private let fileService: FileServiceProtocol
    private let userRulesDirectory: String
    private let skillStore: SkillStoreProtocol
    private let ownership: DeployArtifactOwnershipChecking

    init(fileService: FileServiceProtocol, skillStore: SkillStoreProtocol, userRulesDirectory: String) {
        self.fileService = fileService
        self.userRulesDirectory = userRulesDirectory
        self.skillStore = skillStore
        self.ownership = DeployArtifactOwnership(fileService: fileService)
    }

    func compile(skill: Skill, projectPath: String?) throws {
        try LinkService.validatePathComponent(skill.directoryName)
        let projectDirectory = try projectPath.map { try fileService.requireProjectDirectory(at: $0) }
        let raw = try skillStore.readBody(directoryName: skill.directoryName)
        let body = SkillParser.stripFrontmatter(raw)
        let mdc = generateMDC(skill: skill, body: body)
        let path = outputPath(skill: skill, projectPath: projectPath)
        let occupant = try ownership.cursor(at: path) {
            self.generateLegacyMDC(skill: skill, body: body)
        }
        guard occupant == .absent || occupant.isOwned else { throw ArtifactOwnershipError.occupiedPath(path) }
        if let projectDirectory {
            try fileService.writeFileInProject(at: path, content: mdc, project: projectDirectory)
        } else {
            try fileService.writeFile(at: path, content: mdc)
        }
    }

    @discardableResult
    func remove(skill: Skill, projectPath: String?) throws -> Bool {
        try DeployRemovalService.removeArtifact(removalOperation(skill: skill, platform: .cursor, projectPath: projectPath))
    }

    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool {
        try artifactOccupant(skill: skill, projectPath: projectPath).isOwned
    }

    private func artifactOccupant(skill: Skill, projectPath: String?) throws -> DeployArtifactOccupant {
        guard ProjectDirectory.canAccess(projectPath) else { return .foreign }
        try LinkService.validatePathComponent(skill.directoryName)
        return try ownership.cursor(
            at: outputPath(skill: skill, projectPath: projectPath)
        ) {
            let raw = try self.skillStore.readBody(directoryName: skill.directoryName)
            return self.generateLegacyMDC(skill: skill, body: SkillParser.stripFrontmatter(raw))
        }
    }

    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool {
        guard ProjectDirectory.canAccess(projectPath) else { return false }
        try LinkService.validatePathComponent(skill.directoryName)
        return try ownership.cursor(at: outputPath(skill: skill, projectPath: projectPath), legacyContent: nil) == .owned
    }

    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
        return try ownership.cursorRuleMayExist(at: outputPath(skill: skill, projectPath: projectPath))
    }

    func isUpToDate(skill: Skill, projectPath: String?) -> Bool {
        guard ProjectDirectory.canAccess(projectPath) else { return false }
        let path = outputPath(skill: skill, projectPath: projectPath)
        guard fileService.fileExists(at: path) else { return false }
        guard let raw = try? skillStore.readBody(directoryName: skill.directoryName) else { return false }
        let body = SkillParser.stripFrontmatter(raw)
        let expected = generateMDC(skill: skill, body: body)
        guard let current = try? fileService.readRegularFileData(at: path, maximumBytes: expected.utf8.count) else {
            return false
        }
        return current == Data(expected.utf8)
    }

    func outputPath(skill: Skill, projectPath: String?) -> String {
        DeployPaths(skillsDirectory: "", userSkillsDirectories: [:], cursorUserRulesDirectory: userRulesDirectory)
            .cursorPath(directoryName: skill.directoryName, projectPath: projectPath)
    }

    // MARK: - MDC Generation

    func generateMDC(skill: Skill, body: String) -> String {
        CursorMDC.generate(
            directoryName: skill.directoryName,
            description: skill.skillDescription,
            cursorConfig: skill.cursorConfig,
            body: body
        )
    }

    private func generateLegacyMDC(skill: Skill, body: String) -> String {
        CursorMDC.generateLegacy(directoryName: skill.directoryName, description: skill.skillDescription,
                                 cursorConfig: skill.cursorConfig, body: body)
    }

    func removalFingerprint(skill: Skill) -> CursorRemovalFingerprint? {
        guard let raw = try? skillStore.readBody(directoryName: skill.directoryName) else { return nil }
        return CursorRemovalFingerprint(content: generateLegacyMDC(skill: skill, body: SkillParser.stripFrontmatter(raw)))
    }
}

extension CursorCompiler {
    func removalOperation(skill: Skill, platform: PlatformTarget, projectPath: String?) -> DeployRemovalOperation {
        DeployRemovalOperation(fileService: fileService, path: outputPath(skill: skill, projectPath: projectPath)) {
            guard platform == .cursor else {
                throw ArtifactOwnershipError.couldNotCheck(path: self.outputPath(skill: skill, projectPath: projectPath),
                    reason: "Cursor compiler cannot remove \(platform.rawValue) artifacts")
            }
            return try self.artifactOccupant(skill: skill, projectPath: projectPath)
        }
    }
}
