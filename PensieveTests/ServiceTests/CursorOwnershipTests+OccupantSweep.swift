import Darwin
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    enum Occupant: String, CaseIterable {
        case absent, marked, unmarked, legacy, unreadable, linkToMarked, directory, fifo
        case ownedLink, brokenOwnedLink, otherSkillLink, foreignLink, relativeLink, traversalLink, lookalikeLink, storeLink
        case parentThenCombiningLink, interiorCombiningLink, leadingCombiningTraversalLink

        var combiningTraversalRemainder: String? {
            switch self {
            case .parentThenCombiningLink: "../\u{0301}outside"
            case .interiorCombiningLink: "x/\u{0301}.."
            case .leadingCombiningTraversalLink: "\u{0301}../y"
            default: nil
            }
        }
    }

    func testGeneratedAgentOccupantDeployAndRemovalSweep() throws {
        let targets = PlatformTarget.allCases.flatMap { platform -> [(PlatformTarget, String?)] in
            [(platform, nil)] + (platform.supportsProjectScope ? [(platform, root + "/project")] : [])
        }
        var cases = 0
        for (platform, project) in targets {
            for occupant in Occupant.allCases {
                for removing in [false, true] {
                    try runOccupantCase(platform: platform, project: project, occupant: occupant, removing: removing)
                    cases += 1
                }
            }
        }
        XCTAssertEqual(cases, 380)
        XCTAssertEqual(try files.readFile(at: root + "/marked-target.mdc"), "---\n# pensieve: managed\n---\nTarget")
    }

    func testCombiningMarkTraversalLinkDeployPreservesBytesInEveryScope() throws {
        try verifyCombiningMarkTraversalLinks(removing: false)
    }

    func testCombiningMarkTraversalLinkRemovalPreservesBytesInEveryScope() throws {
        try verifyCombiningMarkTraversalLinks(removing: true)
    }

    private func verifyCombiningMarkTraversalLinks(removing: Bool) throws {
        let links = TestPaths.linkService(fileService: mapped)
        let occupants: [Occupant] = [.parentThenCombiningLink, .interiorCombiningLink, .leadingCombiningTraversalLink]
        var cases = 0
        defer { XCTAssertEqual(cases, 27, "All link agents, supported scopes and target shapes must run") }
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let scopes: [String?] = platform.supportsProjectScope ? [nil, root + "/project"] : [nil]
            for project in scopes {
                let path = links.linkPath(skill: skill, platform: platform, projectPath: project)
                let physical = project == nil ? root + "/user/" + platform.rawValue + "/" + skill.directoryName : path
                // Cover the literal requested shapes and the corresponding project Codex file targets.
                let suffixes = platform == .codex && project != nil ? ["", "/SKILL.md"] : [""]
                for occupant in occupants {
                    for suffix in suffixes {
                        cases += 1
                        if try files.entryExistsWithoutFollowingLinks(at: physical) { try files.deleteFile(at: physical) }
                        let target = try linkTarget(occupant, store: root + "/store/skills", suffix: suffix)
                        try files.createSymlink(at: physical, pointingTo: target)
                        let caseLinks = try traversalLinks(at: path, physical: physical, occupant: occupant, suffix: suffix)
                        let before = try traversalLinkBytes(at: physical)
                        XCTAssertNotNil(before)
                        let label = "\(platform) / project=\(project != nil) / \(occupant) / \(suffix)"
                        if removing {
                            XCTAssertFalse(try caseLinks.unlink(skill: skill, platform: platform, projectPath: project), label)
                        } else {
                            XCTAssertThrowsError(try caseLinks.link(
                                skill: skill, platform: platform, projectPath: project), label) {
                                guard case ArtifactOwnershipError.occupiedPath(let occupied) = $0 else {
                                    return XCTFail("Expected occupied path, got \($0): \(label)")
                                }
                                XCTAssertEqual(occupied, path, label)
                            }
                        }
                        XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: physical), .symlink, label)
                        XCTAssertEqual(try traversalLinkBytes(at: physical), before, label)
                    }
                }
            }
        }
    }

    private func traversalLinkBytes(at path: String) throws -> Data? {
        guard try files.entryTypeWithoutFollowingLinks(at: path) == .symlink else { return nil }
        return Data(try files.symlinkTarget(at: path).utf8)
    }

    private func traversalLinks(at path: String, physical: String, occupant: Occupant, suffix: String) throws -> LinkService {
        let logicalTarget = try linkTarget(occupant, store: TestPaths.skillsDir, suffix: suffix)
        let physicalTarget = try files.symlinkTarget(at: physical)
        // Exact target mappings keep the fixture's grapheme-prefix residual out of ownership's input.
        let boundary = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [
            (logicalTarget, physicalTarget), (path, physical), (TestPaths.skillsDir, root + "/store/skills")
        ], physicalSandbox: root)
        XCTAssertEqual(Data(try boundary.symlinkTarget(at: path).utf8), Data(logicalTarget.utf8))
        return TestPaths.linkService(fileService: boundary)
    }

    private func runOccupantCase(platform: PlatformTarget, project: String?, occupant: Occupant, removing: Bool) throws {
        let links = TestPaths.linkService(fileService: mapped)
        let path = platform.usesSymlinks
            ? links.linkPath(skill: skill, platform: platform, projectPath: project)
            : compiler.outputPath(skill: skill, projectPath: project)
        let physical = project == nil
            ? root + "/user/" + (platform == .cursor ? "rules" : platform.rawValue)
                + "/" + skill.directoryName + (platform == .cursor ? ".mdc" : "")
            : path
        if try files.entryExistsWithoutFollowingLinks(at: physical) { try files.deleteFile(at: physical) }
        try install(occupant, at: physical, linksFile: platform == .codex && project != nil)
        let operationLinks = platform.usesSymlinks && occupant.combiningTraversalRemainder != nil
            ? try traversalLinks(at: path, physical: physical, occupant: occupant,
                                 suffix: platform == .codex && project != nil ? "/SKILL.md" : "") : links
        let before = try snapshot(physical)
        mapped.beforeRuleRead = occupant == .unreadable ? { _ in throw CocoaError(.fileReadNoPermission) } : nil
        let problem = try boundedArtifactOperation(fifo: occupant == .fifo ? physical : nil) {
            try self.operate(platform: platform, project: project, removing: removing, links: operationLinks)
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

    private func operate(platform: PlatformTarget, project: String?, removing: Bool, links: LinkService) throws {
        if platform.usesSymlinks {
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
        if let remainder = occupant.combiningTraversalRemainder { return store + "/" + remainder + suffix }
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
        case .symlink: return "link: " + Data(try files.symlinkTarget(at: path).utf8).base64EncodedString()
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

/// Runs FIFO operations with a held writer and the shared positive-wait deadline. A blocking open/read
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
    let finished = done.wait(timeout: .now() + TestWait.hostedActionTimeoutSeconds) == .success
    close(writer)
    guard finished else {
        _ = done.wait(timeout: .now() + 2) // upper-bound: Bound cleanup after releasing a blocked FIFO reader.
        XCTFail("Artifact operation blocked on FIFO beyond the shared wait bound")
        throw CocoaError(.fileReadUnknown)
    }
    return result.error
}

private final class ArtifactOperationResult { var error: Error? }
