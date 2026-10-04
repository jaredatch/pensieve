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
            XCTAssertThrowsError(try deploy(platform, to: project))
            XCTAssertEqual(files.fileIdentity(at: output, followingLinks: false), identity)
            XCTAssertEqual(try files.readFile(at: output + "/user-file"), "Preserved")
            mapped.beforeArtifactCreation = nil
        }
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
