import XCTest
@testable import Pensieve

extension LinkServiceTests {
    private func scriptedService(
        state: LinkServiceScriptedPathState
    ) -> LinkServiceScriptedContext {
        let skill = makeSkill()
        let projectPath = tempDir + "/scripted-project"
        let linkPath = linkService.linkPath(
            skill: skill, platform: .claudeCode, projectPath: projectPath)
        let canonicalDirectory = Constants.pensieveSkillsDir + "/" + skill.directoryName
        let scriptedFileService = LinkServiceScriptedFileService(
            linkPath: linkPath, canonicalDirectory: canonicalDirectory, state: state)
        return LinkServiceScriptedContext(
            service: LinkService(fileService: scriptedFileService),
            fileService: scriptedFileService,
            projectPath: projectPath)
    }

    private func assertLinkReplacesSymlink(state: LinkServiceScriptedPathState) throws {
        let context = scriptedService(state: state)
        let skill = makeSkill()
        let link = context.service.linkPath(
            skill: skill, platform: .claudeCode, projectPath: context.projectPath)
        let expectedTarget = context.service.targetPath(
            skill: skill, platform: .claudeCode, projectPath: context.projectPath)
        switch state.symlinkTarget {
        case .canonical:
            XCTAssertEqual(try context.fileService.symlinkTarget(at: link), expectedTarget)
        case .retargeted:
            XCTAssertNotEqual(try context.fileService.symlinkTarget(at: link), expectedTarget)
        case .unavailable:
            XCTAssertThrowsError(try context.fileService.symlinkTarget(at: link))
        }
        try context.service.link(
            skill: skill, platform: .claudeCode, projectPath: context.projectPath)
        XCTAssertTrue(context.fileService.createSymlinkCalled)
        XCTAssertFalse(context.fileService.deleteFileCalled)
    }

    func testLinkRefusesRealDirectoryAndPreservesIt() throws {
        let skill = makeSkill()
        let projectPath = tempDir + "/real-directory-project"
        let occupant = linkService.linkPath(
            skill: skill, platform: .claudeCode, projectPath: projectPath)
        let originalPath = occupant + "/original.txt"
        let originalContents = "real directory contents"
        try fileService.writeFile(at: originalPath, content: originalContents)

        let canonicalDirectory = Constants.pensieveSkillsDir + "/" + skill.directoryName
        let substituteDirectory = tempDir + "/canonical-directory-skill"
        try fileService.createDirectory(at: substituteDirectory)
        let service = LinkService(fileService: LinkServiceCanonicalDirectoryFileService(
            wrapped: fileService,
            canonicalDirectory: canonicalDirectory,
            substituteDirectory: substituteDirectory))

        XCTAssertThrowsError(try service.link(
            skill: skill, platform: .claudeCode, projectPath: projectPath
        )) { error in
            guard case LinkError.occupiedByRealPath(let path) = error else {
                return XCTFail("Expected occupiedByRealPath, got \(error)")
            }
            XCTAssertEqual(path, occupant)
        }
        XCTAssertTrue(fileService.directoryExists(at: occupant))
        XCTAssertEqual(try fileService.readFile(at: originalPath), originalContents)
    }

    func testLinkRefusesRealFileAndPreservesIt() throws {
        let skill = makeSkill()
        let projectPath = tempDir + "/real-file-project"
        let occupant = linkService.linkPath(
            skill: skill, platform: .claudeCode, projectPath: projectPath)
        let originalContents = "real file contents"
        try fileService.writeFile(at: occupant, content: originalContents)

        let canonicalDirectory = Constants.pensieveSkillsDir + "/" + skill.directoryName
        let substituteDirectory = tempDir + "/canonical-file-skill"
        try fileService.createDirectory(at: substituteDirectory)
        let service = LinkService(fileService: LinkServiceCanonicalDirectoryFileService(
            wrapped: fileService,
            canonicalDirectory: canonicalDirectory,
            substituteDirectory: substituteDirectory))

        XCTAssertThrowsError(try service.link(
            skill: skill, platform: .claudeCode, projectPath: projectPath
        )) { error in
            guard case LinkError.occupiedByRealPath(let path) = error else {
                return XCTFail("Expected occupiedByRealPath, got \(error)")
            }
            XCTAssertEqual(path, occupant)
        }
        XCTAssertTrue(fileService.fileExists(at: occupant))
        XCTAssertEqual(try fileService.readFile(at: occupant), originalContents)
    }

    func testUnlinkLeavesRealDirectoryIntactWithoutThrowing() throws {
        let skill = makeSkill()
        let projectPath = tempDir + "/unlink-real-directory-project"
        let occupant = linkService.linkPath(
            skill: skill, platform: .claudeCode, projectPath: projectPath)
        let originalPath = occupant + "/original.txt"
        let originalContents = "unlink directory contents"
        try fileService.writeFile(at: originalPath, content: originalContents)

        XCTAssertNoThrow(try linkService.unlink(
            skill: skill, platform: .claudeCode, projectPath: projectPath))
        XCTAssertTrue(fileService.directoryExists(at: occupant))
        XCTAssertEqual(try fileService.readFile(at: originalPath), originalContents)
    }

    func testUnlinkLeavesRealFileIntactWithoutThrowing() throws {
        let skill = makeSkill()
        let projectPath = tempDir + "/unlink-real-file-project"
        let occupant = linkService.linkPath(
            skill: skill, platform: .claudeCode, projectPath: projectPath)
        let originalContents = "unlink file contents"
        try fileService.writeFile(at: occupant, content: originalContents)

        XCTAssertNoThrow(try linkService.unlink(
            skill: skill, platform: .claudeCode, projectPath: projectPath))
        XCTAssertTrue(fileService.fileExists(at: occupant))
        XCTAssertEqual(try fileService.readFile(at: occupant), originalContents)
    }

    func testRefusalAttemptsNoMutation() {
        for state in [LinkServiceScriptedPathState.realDirectory, .realFile] {
            let linkContext = scriptedService(state: state)
            XCTAssertThrowsError(try linkContext.service.link(
                skill: makeSkill(), platform: .claudeCode, projectPath: linkContext.projectPath))
            XCTAssertFalse(linkContext.fileService.createSymlinkCalled)
            XCTAssertFalse(linkContext.fileService.deleteFileCalled)

            let unlinkContext = scriptedService(state: state)
            XCTAssertNoThrow(try unlinkContext.service.unlink(
                skill: makeSkill(), platform: .claudeCode, projectPath: unlinkContext.projectPath))
            XCTAssertFalse(unlinkContext.fileService.createSymlinkCalled)
            XCTAssertFalse(unlinkContext.fileService.deleteFileCalled)
        }
    }

    func testLinkReplacesCorrectSymlink() throws {
        try assertLinkReplacesSymlink(state: .validDirectorySymlink)
    }

    func testLinkReplacesRetargetedSymlink() throws {
        let context = scriptedService(state: .retargetedDirectorySymlink)
        XCTAssertThrowsError(try context.service.link(
            skill: makeSkill(), platform: .claudeCode, projectPath: context.projectPath)) { error in
            guard case ArtifactOwnershipError.occupiedPath = error else { return XCTFail("Expected ownership error: \(error)") }
        }
        XCTAssertFalse(context.fileService.createSymlinkCalled)
    }

    func testLinkReplacesBrokenSymlink() throws {
        try assertLinkReplacesSymlink(state: .brokenSymlink)
    }

    func testMissingPathLinkCreatesAndUnlinkDoesNotDelete() throws {
        let linkContext = scriptedService(state: .missing)
        try linkContext.service.link(
            skill: makeSkill(), platform: .claudeCode, projectPath: linkContext.projectPath)
        XCTAssertTrue(linkContext.fileService.createSymlinkCalled)

        let unlinkContext = scriptedService(state: .missing)
        XCTAssertNoThrow(try unlinkContext.service.unlink(
            skill: makeSkill(), platform: .claudeCode, projectPath: unlinkContext.projectPath))
        XCTAssertFalse(unlinkContext.fileService.deleteFileCalled)
    }

    func testUnlinkRemovesCorrectRetargetedAndBrokenSymlinks() {
        for state in [
            LinkServiceScriptedPathState.validDirectorySymlink,
            .brokenSymlink
        ] {
            let context = scriptedService(state: state)
            XCTAssertNoThrow(try context.service.unlink(
                skill: makeSkill(), platform: .claudeCode, projectPath: context.projectPath))
            XCTAssertTrue(context.fileService.deleteFileCalled)
        }
        let context = scriptedService(state: .retargetedDirectorySymlink)
        XCTAssertNoThrow(try context.service.unlink(
            skill: makeSkill(), platform: .claudeCode, projectPath: context.projectPath))
        XCTAssertFalse(context.fileService.deleteFileCalled)
    }
}
