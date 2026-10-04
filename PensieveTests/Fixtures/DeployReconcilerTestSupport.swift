import Foundation
import SwiftData
@testable import Pensieve

struct DeployRecordedLink: Hashable {
    let directoryName: String
    let platform: PlatformTarget
    let projectPath: String?
}

struct DeployRecordedCursorCall: Hashable {
    let directoryName: String
    let projectPath: String?
}

struct DeployStubFailure: LocalizedError {
    let errorDescription: String? = "stub failure"
}

struct DeployStubDetection: AgentDetectionServiceProtocol {
    let installed: [PlatformTarget]

    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}

final class DeployRecordingFileService: FileServiceProtocol {
    var files: Set<String> = []
    var symlinks: Set<String> = []
    var contents: [String: String] = [:]

    func readFile(at path: String) throws -> String { contents[path] ?? "" }
    func writeFile(at path: String, content: String) throws {
        files.insert(path)
        contents[path] = content
    }
    func deleteFile(at path: String) throws {
        files.remove(path)
        symlinks.remove(path)
        contents.removeValue(forKey: path)
    }
    func fileExists(at path: String) -> Bool { files.contains(path) || contents[path] != nil }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws { symlinks.insert(linkPath) }
    func symlinkTarget(at path: String) throws -> String { "/wrong-target" }
    func isSymlink(at path: String) -> Bool { symlinks.contains(path) }
    func isRegularFile(at path: String) -> Bool { true }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "hash" }
}

final class DeployRecordingLinkService: LinkServiceProtocol {
    let fileService: DeployRecordingFileService
    var linkCalls: [DeployRecordedLink] = []
    var unlinkCalls: [DeployRecordedLink] = []
    var throwOnLink: Set<PlatformTarget> = []
    var throwOnUnlink: Set<PlatformTarget> = []
    var throwOnLinkPaths: Set<String> = []
    var throwOnUnlinkPaths: Set<String> = []
    var onLink: (() -> Void)?

    init(fileService: DeployRecordingFileService) {
        self.fileService = fileService
    }

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        onLink?()
        linkCalls.append(DeployRecordedLink(
            directoryName: skill.directoryName,
            platform: platform,
            projectPath: projectPath
        ))
        let path = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        if throwOnLink.contains(platform) || throwOnLinkPaths.contains(path) { throw DeployStubFailure() }
        fileService.symlinks.insert(path)
    }

    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        unlinkCalls.append(DeployRecordedLink(
            directoryName: skill.directoryName,
            platform: platform,
            projectPath: projectPath
        ))
        let path = linkPath(skill: skill, platform: platform, projectPath: projectPath)
        if throwOnUnlink.contains(platform) || throwOnUnlinkPaths.contains(path) { throw DeployStubFailure() }
        try fileService.deleteFile(at: path)
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        fileService.symlinks.contains(linkPath(skill: skill, platform: platform, projectPath: projectPath))
    }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/links/" + platform.rawValue + "/" + skill.directoryName
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/targets/" + platform.rawValue + "/" + skill.directoryName
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

final class DeployRecordingCursorCompiler: CursorCompilerProtocol {
    let fileService: DeployRecordingFileService
    var compileCalls: [DeployRecordedCursorCall] = []
    var removeCalls: [DeployRecordedCursorCall] = []
    var throwOnCompile = false
    var throwOnRemove = false

    init(fileService: DeployRecordingFileService) {
        self.fileService = fileService
    }

    func compile(skill: Skill, projectPath: String?) throws {
        compileCalls.append(DeployRecordedCursorCall(directoryName: skill.directoryName, projectPath: projectPath))
        if throwOnCompile { throw DeployStubFailure() }
        fileService.files.insert(outputPath(skill: skill, projectPath: projectPath))
    }

    func remove(skill: Skill, projectPath: String?) throws {
        removeCalls.append(DeployRecordedCursorCall(directoryName: skill.directoryName, projectPath: projectPath))
        if throwOnRemove { throw DeployStubFailure() }
        try fileService.deleteFile(at: outputPath(skill: skill, projectPath: projectPath))
    }

    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }

    func outputPath(skill: Skill, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/cursor/" + skill.directoryName + ".mdc"
    }
}
