import XCTest
import SwiftData
@testable import Pensieve

typealias CategoryFixturePensieveCategory = Pensieve.Category

struct CategoryFixtureRecordedLink: Hashable {
    let directoryName: String
    let platform: PlatformTarget
    let projectPath: String?
}

struct CategoryFixtureRecordedCursorCall: Hashable {
    let directoryName: String
    let projectPath: String?
}

struct CategoryFixtureSeededCategory {
    let skill: Skill
    let firstProject: Project
    let secondProject: Project
    let category: CategoryFixturePensieveCategory
}

struct CategoryFixtureStubFailure: LocalizedError { let errorDescription: String? = "stub failure" }

struct CategoryFixtureStubDetection: AgentDetectionServiceProtocol {
    let installed: [PlatformTarget]

    func isInstalled(_ platform: PlatformTarget) -> Bool { installed.contains(platform) }
    func installedPlatforms() -> [PlatformTarget] { installed }
}

final class CategoryFixtureRecordingLinkService: LinkServiceProtocol {
    var fileService: CategoryFixtureStubFileService?
    var linkCalls: [CategoryFixtureRecordedLink] = []
    var unlinkCalls: [CategoryFixtureRecordedLink] = []
    var throwOnLink: Set<PlatformTarget> = []
    var throwOnUnlink: Set<PlatformTarget> = []

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        linkCalls.append(CategoryFixtureRecordedLink(
            directoryName: skill.directoryName, platform: platform, projectPath: projectPath
        ))
        if throwOnLink.contains(platform) { throw CategoryFixtureStubFailure() }
        fileService?.links.insert(linkPath(skill: skill, platform: platform, projectPath: projectPath))
    }

    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        unlinkCalls.append(CategoryFixtureRecordedLink(
            directoryName: skill.directoryName, platform: platform, projectPath: projectPath
        ))
        if throwOnUnlink.contains(platform) { throw CategoryFixtureStubFailure() }
        fileService?.links.remove(linkPath(skill: skill, platform: platform, projectPath: projectPath))
    }

    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        fileService?.isSymlink(at: linkPath(skill: skill, platform: platform, projectPath: projectPath)) == true
    }

    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/links/" + platform.rawValue + "/" + skill.directoryName
    }

    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/targets/" + skill.directoryName
    }

    func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
}

final class CategoryFixtureRecordingCursorCompiler: CursorCompilerProtocol {
    var fileService: CategoryFixtureStubFileService?
    var compileCalls: [CategoryFixtureRecordedCursorCall] = []
    var removeCalls: [CategoryFixtureRecordedCursorCall] = []
    var throwOnCompile = false
    var throwOnRemove = false

    func compile(skill: Skill, projectPath: String?) throws {
        compileCalls.append(CategoryFixtureRecordedCursorCall(directoryName: skill.directoryName, projectPath: projectPath))
        if throwOnCompile { throw CategoryFixtureStubFailure() }
        fileService?.files.insert(outputPath(skill: skill, projectPath: projectPath))
    }

    func remove(skill: Skill, projectPath: String?) throws {
        removeCalls.append(CategoryFixtureRecordedCursorCall(directoryName: skill.directoryName, projectPath: projectPath))
        if throwOnRemove { throw CategoryFixtureStubFailure() }
        fileService?.files.remove(outputPath(skill: skill, projectPath: projectPath))
    }

    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }

    func outputPath(skill: Skill, projectPath: String?) -> String {
        (projectPath ?? "/tmp/user-wide") + "/cursor/" + skill.directoryName + ".mdc"
    }
}

final class CategoryFixtureStubFileService: FileServiceProtocol {
    var links: Set<String> = []
    var files: Set<String> = []
    func readFile(at path: String) throws -> String { "" }
    func writeFile(at path: String, content: String) throws {}
    func deleteFile(at path: String) throws {}
    func fileExists(at path: String) -> Bool { links.contains(path) || files.contains(path) }
    func isExecutableFile(at path: String) -> Bool { false }
    func directoryExists(at path: String) -> Bool { false }
    func directoryExistsFollowingLinks(at path: String) throws -> Bool { path.hasPrefix("/tmp/") }
    func createDirectory(at path: String) throws {}
    func deleteDirectory(at path: String) throws {}
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {}
    func symlinkTarget(at path: String) throws -> String { "" }
    func isSymlink(at path: String) -> Bool { links.contains(path) }
    func isRegularFile(at path: String) -> Bool { true }
    func listDirectory(at path: String) throws -> [String] { [] }
    func contentsHash(at path: String) throws -> String { "hash" }
}
