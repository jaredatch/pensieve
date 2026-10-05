import XCTest
@testable import Pensieve

extension ProjectFolderDeployTests {
    func testDeletionAfterCheckBeforeFirstDirectoryCreationForFourAgents() throws {
        for platform in platforms {
            let ancestor = root + "/race-\(platform.rawValue)"
            let project = ancestor + "/project"
            try files.createDirectory(at: project)
            var deleted = false
            mapped.beforeDirectoryCreation = { _ in
                if !deleted {
                    deleted = true
                    try self.files.deleteDirectory(at: ancestor)
                }
            }
            assertMissing(platform, project: project)
            XCTAssertTrue(deleted, "Must delete after the project check and before folder creation")
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: ancestor))
            mapped.beforeDirectoryCreation = nil
        }
    }

    func testDeletionBetweenInteriorDirectoryCreationsForThreeAgents() throws {
        for platform in [.claudeCode, .grok, .cursor] as [PlatformTarget] {
            let project = root + "/race-later-\(platform.rawValue)"
            try files.createDirectory(at: project)
            var creations = 0
            mapped.beforeDirectoryCreation = { path in
                creations += 1
                if creations == 2 {
                    let parent = (path as NSString).deletingLastPathComponent
                    XCTAssertTrue(self.files.directoryExists(at: parent))
                    try self.files.deleteDirectory(at: project)
                }
            }
            assertMissing(platform, project: project)
            XCTAssertEqual(creations, 2)
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: project))
            mapped.beforeDirectoryCreation = nil
        }
    }

    func testDeletionAfterFoldersBeforeArtifactWriteForFourAgents() throws {
        for platform in platforms {
            let project = root + "/race-artifact-\(platform.rawValue)"
            try files.createDirectory(at: project)
            var deleted = false
            mapped.beforeArtifactCreation = { path in
                XCTAssertTrue(self.files.directoryExists(at: (path as NSString).deletingLastPathComponent))
                deleted = true
                try self.files.deleteDirectory(at: project)
            }
            assertMissing(platform, project: project)
            XCTAssertTrue(deleted, "Must reach the artifact write with its interior folders already present")
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: project))
            mapped.beforeArtifactCreation = nil
        }
    }

    func testProjectLinkLoopReportsCouldNotCheckForFourAgents() throws {
        let project = root + "/loop"
        try files.createSymlink(at: project, pointingTo: project)
        for platform in platforms {
            XCTAssertThrowsError(try deploy(platform, to: project)) { error in
                guard case ProjectFolderError.couldNotCheck(let path, let reason) = error else {
                    return XCTFail("Expected couldn't-check error for link loop, got \(error)")
                }
                XCTAssertEqual(path, project)
                XCTAssertFalse(reason.isEmpty)
            }
            XCTAssertEqual(try files.symlinkTarget(at: project), project)
        }
    }

    func testInteriorFileFailurePreservesOccupantAndIsNotMissingProject() throws {
        for platform in platforms {
            let project = root + "/occupied-\(platform.rawValue)"
            let interior = artifact(platform, in: project).dropFirst(project.count + 1).split(separator: "/")[0]
            let occupant = project + "/" + interior
            try files.writeFile(at: occupant, content: "Preserved")
            XCTAssertThrowsError(try deploy(platform, to: project)) { error in
                XCTAssertFalse(error is ProjectFolderError, "Existing project with an interior occupant is not missing")
            }
            XCTAssertEqual(try files.readFile(at: occupant), "Preserved")
        }
    }
}
