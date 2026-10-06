import Darwin
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    enum Occupant: String, CaseIterable {
        case absent, marked, unmarked, legacy, unreadable, linkToMarked, directory, fifo
        case ownedLink, brokenOwnedLink, otherSkillLink, foreignLink, relativeLink, traversalLink, lookalikeLink, storeLink
    }

    func testGeneratedAgentOccupantDeployAndRemovalSweep() throws {
        let targets = PlatformTarget.allCases.flatMap { platform -> [(PlatformTarget, String?)] in
            [(platform, nil)] + (platform.supportsProjectScope ? [(platform, root + "/project")] : [])
        }
        var cases = 0
        for name in Self.ownershipSkillNames {
            try useOwnershipSkill(named: name)
            for (platform, project) in targets {
                for occupant in Occupant.allCases {
                    for removing in [false, true] {
                        try runOccupantCase(platform: platform, project: project, occupant: occupant, removing: removing)
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 320 * Self.ownershipSkillNames.count)
        XCTAssertEqual(try files.readFile(at: root + "/marked-target.mdc"), "---\n# pensieve: managed\n---\nTarget")
    }

    private func runOccupantCase(platform: PlatformTarget, project: String?, occupant: Occupant, removing: Bool) throws {
        let links = LinkService(fileService: mapped)
        let path = platform.usesSymlinks
            ? links.linkPath(skill: skill, platform: platform, projectPath: project)
            : compiler.outputPath(skill: skill, projectPath: project)
        let physical = project == nil
            ? root + "/user/" + (platform == .cursor ? "rules" : platform.rawValue)
                + "/" + skill.directoryName + (platform == .cursor ? ".mdc" : "")
            : path
        if try files.entryExistsWithoutFollowingLinks(at: physical) { try files.deleteFile(at: physical) }
        try install(occupant, at: physical, linksFile: platform == .codex && project != nil)
        let before = try snapshot(physical)
        mapped.beforeRuleRead = occupant == .unreadable ? { _ in throw CocoaError(.fileReadNoPermission) } : nil
        let problem = try boundedArtifactOperation(fifo: occupant == .fifo ? physical : nil) {
            try self.operate(platform: platform, project: project, removing: removing)
        }
        mapped.beforeRuleRead = nil
        let owned = platform.usesSymlinks
            ? [.ownedLink, .brokenOwnedLink, .otherSkillLink].contains(occupant)
            : [.marked, .legacy].contains(occupant)
        let unknown = platform == .cursor && occupant == .unreadable
        let label = "\(platform) / project=\(project != nil) / \(occupant) / removing=\(removing)"
        if unknown { assertCouldNotCheck(problem, path: path) } else if removing || owned || occupant == .absent {
            XCTAssertNil(problem, label)
        } else {
            XCTAssertNotNil(problem, label)
            XCTAssertTrue(problem?.localizedDescription.contains(path) == true, label)
        }
        if unknown || (!owned && occupant != .absent) {
            XCTAssertEqual(try snapshot(physical), before, label)
        } else if removing {
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: physical), label)
        } else if platform.usesSymlinks {
            XCTAssertEqual(try mapped.symlinkTarget(at: path),
                           links.targetPath(skill: skill, platform: platform, projectPath: project), label)
        } else {
            let header = try files.readRegularFileHeader(at: physical, maximumBytes: 1_024)
            XCTAssertTrue(CursorMDC.hasOwnershipMark(in: header), label)
        }
    }

    private func operate(platform: PlatformTarget, project: String?, removing: Bool) throws {
        if platform.usesSymlinks {
            let links = LinkService(fileService: mapped)
            if removing { try links.unlink(skill: skill, platform: platform, projectPath: project) } else {
                try links.link(skill: skill, platform: platform, projectPath: project)
            }
        } else if removing { try compiler.remove(skill: skill, projectPath: project) } else {
            try compiler.compile(skill: skill, projectPath: project)
        }
    }

    private func install(_ occupant: Occupant, at path: String, linksFile: Bool) throws {
        try files.createDirectory(at: (path as NSString).deletingLastPathComponent)
        let suffix = linksFile ? "/SKILL.md" : ""
        let store = root + "/store/skills"
        switch occupant {
        case .absent: break
        case .marked, .unreadable: try files.writeFile(at: path, content: "---\n# pensieve: managed\n---\nStale")
        case .unmarked: try files.writeFile(at: path, content: "User's bytes")
        case .legacy: try files.writeFile(at: path, content: "---\ndescription: Description\nalwaysApply: false\n---\n\n# Body\n")
        case .directory: try files.writeFile(at: path + "/payload", content: "Directory sentinel")
        case .fifo: XCTAssertEqual(mkfifo(path, 0o600), 0)
        case .linkToMarked:
            let target = root + "/marked-target.mdc"
            try files.writeFile(at: target, content: "---\n# pensieve: managed\n---\nTarget")
            try files.createSymlink(at: path, pointingTo: target)
        default:
            let target = try linkTarget(occupant, store: store, suffix: suffix)
            try files.createSymlink(at: path, pointingTo: target)
        }
    }

    private func linkTarget(_ occupant: Occupant, store: String, suffix: String) throws -> String {
        switch occupant {
        case .ownedLink: return store + "/" + skill.directoryName + suffix
        case .brokenOwnedLink: return store + "/gone" + suffix
        case .otherSkillLink:
            try files.writeFile(at: store + "/other/SKILL.md", content: "Other sentinel")
            return store + "/other" + suffix
        case .foreignLink: return root + "/outside/skill"
        case .relativeLink: return "../relative"
        case .traversalLink: return store + "/alias/../outside" + suffix
        case .lookalikeLink: return store + "-old/skill" + suffix
        default: return store
        }
    }

    private func snapshot(_ path: String) throws -> String {
        guard let type = try files.entryTypeWithoutFollowingLinks(at: path) else { return "absent" }
        switch type {
        case .symlink: return "link: " + (try files.symlinkTarget(at: path))
        case .regular: return "file: " + (try files.readData(at: path)).base64EncodedString()
        case .directory: return "directory: " + (try files.readFile(at: path + "/payload"))
        case .other: return "fifo"
        }
    }

    func assertCouldNotCheck(_ error: Error?, path: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let error, case ArtifactOwnershipError.couldNotCheck(let actual, _) = error else {
            return XCTFail("Expected couldn't-check, got \(String(describing: error))", file: file, line: line)
        }
        XCTAssertEqual(actual, path, file: file, line: line)
    }
}

/// Runs FIFO operations with a held writer and a two-second deadline. A blocking open/read
/// completes only after the deadline closes the writer, and fails the test. This bounds FIFO
/// reads, not arbitrary worker deadlocks. The worker hands its result back through the semaphore.
private func boundedArtifactOperation(fifo: String?, operation: @escaping () throws -> Void) throws -> Error? {
    guard let fifo else { do { try operation(); return nil } catch { return error } }
    let writer = open(fifo, O_RDWR | O_NONBLOCK)
    guard writer >= 0 else { throw CocoaError(.fileReadUnknown) }
    let result = ArtifactOperationResult()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        do { try operation() } catch { result.error = error }
        done.signal()
    }
    let finished = done.wait(timeout: .now() + 2) == .success
    close(writer)
    guard finished else {
        _ = done.wait(timeout: .now() + 2)
        XCTFail("Artifact operation blocked on FIFO beyond two seconds")
        throw CocoaError(.fileReadUnknown)
    }
    return result.error
}

private final class ArtifactOperationResult { var error: Error? }
