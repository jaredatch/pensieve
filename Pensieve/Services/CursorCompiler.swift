import Foundation
import CryptoKit

// MARK: - Protocol

protocol CursorCompilerProtocol {
    /// Generate and write .mdc file from skill + Cursor config
    func compile(skill: Skill, projectPath: String?) throws
    /// Remove compiled .mdc file
    func remove(skill: Skill, projectPath: String?) throws
    /// Check if .mdc is up to date (content hash comparison)
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool
    /// Get the output path for a compiled .mdc file
    func outputPath(skill: Skill, projectPath: String?) -> String
}

// MARK: - Implementation

final class CursorCompiler: CursorCompilerProtocol {
    private let fileService: FileServiceProtocol
    private let skillStore: SkillStoreProtocol

    init(fileService: FileServiceProtocol, skillStore: SkillStoreProtocol) {
        self.fileService = fileService
        self.skillStore = skillStore
    }

    func compile(skill: Skill, projectPath: String?) throws {
        let projectDirectory = try projectPath.map { try fileService.requireProjectDirectory(at: $0) }
        let raw = try skillStore.readBody(directoryName: skill.directoryName)
        let body = SkillParser.stripFrontmatter(raw)
        let mdc = generateMDC(skill: skill, body: body)
        let path = outputPath(skill: skill, projectPath: projectPath)
        if let projectDirectory {
            try fileService.writeFileInProject(at: path, content: mdc, project: projectDirectory)
        } else {
            try fileService.writeFile(at: path, content: mdc)
        }
    }

    func remove(skill: Skill, projectPath: String?) throws {
        guard ProjectDirectory.canAccess(projectPath) else { return }
        let path = outputPath(skill: skill, projectPath: projectPath)
        guard fileService.fileExists(at: path) else { return }
        try fileService.deleteFile(at: path)
    }

    func isUpToDate(skill: Skill, projectPath: String?) -> Bool {
        guard ProjectDirectory.canAccess(projectPath) else { return false }
        let path = outputPath(skill: skill, projectPath: projectPath)
        guard fileService.fileExists(at: path) else { return false }
        guard let raw = try? skillStore.readBody(directoryName: skill.directoryName) else { return false }
        let body = SkillParser.stripFrontmatter(raw)
        let expected = generateMDC(skill: skill, body: body)
        guard let current = try? fileService.readFile(at: path) else { return false }
        return current == expected
    }

    func outputPath(skill: Skill, projectPath: String?) -> String {
        DeployPaths.cursorPath(directoryName: skill.directoryName, projectPath: projectPath)
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
}
