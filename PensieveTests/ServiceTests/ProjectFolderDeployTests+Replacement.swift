import Darwin
import XCTest
@testable import Pensieve

extension ProjectFolderDeployTests {
    func testDirectoryAppearingBeforeLinkWriteIsPreservedForThreeAgents() throws {
        for platform in platforms where platform.usesSymlinks {
            let project = root + "/late-directory-\(platform.rawValue)"
            let output = artifact(platform, in: project)
            try files.createDirectory(at: project)
            var identity: FileIdentity?
            mapped.beforeArtifactCreation = { path in
                XCTAssertEqual(path, output)
                try self.files.writeFile(at: path + "/user-file", content: "Preserved")
                identity = self.files.fileIdentity(at: path, followingLinks: false)
            }
            XCTAssertThrowsError(try deploy(platform, to: project)) { error in
                self.assertOccupied(error, path: output)
            }
            XCTAssertEqual(files.fileIdentity(at: output, followingLinks: false), identity)
            XCTAssertEqual(try files.readFile(at: output + "/user-file"), "Preserved")
            mapped.beforeArtifactCreation = nil
        }
    }

    func testFileAppearingBeforeLinkWriteIsPreservedForThreeAgents() throws {
        for platform in platforms where platform.usesSymlinks {
            let project = root + "/late-file-\(platform.rawValue)"
            let output = artifact(platform, in: project)
            try files.createDirectory(at: project)
            var identity: FileIdentity?
            mapped.beforeArtifactCreation = { path in
                XCTAssertEqual(path, output)
                try self.files.writeFile(at: path, content: "Preserved")
                identity = self.files.fileIdentity(at: path, followingLinks: false)
            }
            XCTAssertThrowsError(try deploy(platform, to: project)) { error in
                self.assertOccupied(error, path: output)
            }
            XCTAssertNotNil(identity, "Must reach the writer after the up-front occupancy check")
            XCTAssertEqual(files.fileIdentity(at: output, followingLinks: false), identity)
            XCTAssertEqual(try files.readFile(at: output), "Preserved")
            mapped.beforeArtifactCreation = nil
        }
    }

    func testLateUserWideFilesArePreservedAndReportOccupiedForFiveAgents() throws {
        try assertLateUserWideOccupants(directory: false)
    }

    func testLateUserWideDirectoriesArePreservedAndReportOccupiedForFiveAgents() throws {
        try assertLateUserWideOccupants(directory: true)
    }

    private func assertLateUserWideOccupants(directory: Bool) throws {
        for platform in PlatformTarget.allCases where platform.usesSymlinks {
            let output = links.linkPath(skill: skill, platform: platform, projectPath: nil)
            var physical = ""
            var identity: FileIdentity?
            mapped.beforeArtifactCreation = { path in
                physical = path
                try self.files.writeFile(at: directory ? path + "/child" : path, content: "Preserved")
                identity = self.files.fileIdentity(at: path, followingLinks: false)
            }
            XCTAssertThrowsError(try deploy(platform, to: nil)) { error in
                self.assertOccupied(error, path: output)
            }
            XCTAssertNotNil(identity, "Must reach the user-wide writer after the occupancy check")
            XCTAssertEqual(files.fileIdentity(at: physical, followingLinks: false), identity)
            XCTAssertEqual(try files.readFile(at: directory ? physical + "/child" : physical), "Preserved")
            mapped.beforeArtifactCreation = nil
        }
    }

    private func assertOccupied(_ error: Error, path: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case LinkError.occupiedByRealPath(let actual) = error else {
            return XCTFail("Expected occupiedByRealPath, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(actual, path, file: file, line: line)
    }

    func testWriteErrorSurvivesProjectRecheckFailureForFourAgents() throws {
        for platform in platforms {
            let project = root + "/write-error-\(platform.rawValue)"
            try files.createDirectory(at: project)
            var writeFailed = false
            mapped.beforeArtifactCreation = { _ in
                writeFailed = true
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }
            mapped.beforeProjectProbe = { path in
                if path == project && writeFailed {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
            }
            XCTAssertThrowsError(try deploy(platform, to: project)) { error in
                XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
                XCTAssertEqual((error as NSError).code, Int(ENOSPC), "Keep the original write error")
            }
            XCTAssertTrue(writeFailed)
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: artifact(platform, in: project)))
            mapped.beforeProjectProbe = nil
            mapped.beforeArtifactCreation = nil
        }
    }
}
