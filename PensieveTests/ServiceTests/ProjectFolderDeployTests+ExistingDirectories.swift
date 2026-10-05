import XCTest
@testable import Pensieve

extension ProjectFolderDeployTests {
    func testExistingInteriorDirectoriesAreReusedForFourAgents() throws {
        for platform in platforms {
            let project = root + "/existing-\(platform.rawValue)"
            let parent = (artifact(platform, in: project) as NSString).deletingLastPathComponent
            try files.createDirectory(at: parent)
            try files.writeFile(at: parent + "/user-file", content: "Preserved")
            let identity = files.fileIdentity(at: parent, followingLinks: true)

            XCTAssertNoThrow(try deploy(platform, to: project))
            XCTAssertNoThrow(try deploy(platform, to: project))

            XCTAssertEqual(files.fileIdentity(at: parent, followingLinks: true), identity)
            XCTAssertEqual(try files.readFile(at: parent + "/user-file"), "Preserved")
            XCTAssertTrue(try files.entryExistsWithoutFollowingLinks(at: artifact(platform, in: project)))
            if platform.usesSymlinks {
                XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: project))
            } else {
                XCTAssertTrue(compiler.isUpToDate(skill: skill, projectPath: project))
            }
        }
    }

    func testExistingLinkedInteriorDirectoriesAreReusedForFourAgents() throws {
        for platform in platforms {
            let project = root + "/linked-interior-\(platform.rawValue)"
            let target = project + "/shared"
            let output = artifact(platform, in: project)
            let relative = output.dropFirst(project.count + 1).split(separator: "/")
            let linked = project + "/" + relative[0]
            let parent = (output as NSString).deletingLastPathComponent
            try files.createDirectory(at: target)
            try files.createSymlink(at: linked, pointingTo: target)
            try files.createDirectory(at: parent)
            let identity = files.fileIdentity(at: linked, followingLinks: false)

            XCTAssertNoThrow(try deploy(platform, to: project))
            XCTAssertNoThrow(try deploy(platform, to: project))

            XCTAssertEqual(try files.symlinkTarget(at: linked), target)
            XCTAssertEqual(files.fileIdentity(at: linked, followingLinks: false), identity)
            let actual = target + output.dropFirst(linked.count)
            XCTAssertTrue(try files.entryExistsWithoutFollowingLinks(at: actual))
            if platform.usesSymlinks {
                XCTAssertTrue(links.isLinked(skill: skill, platform: platform, projectPath: project))
            } else {
                XCTAssertTrue(compiler.isUpToDate(skill: skill, projectPath: project))
            }
        }
    }
}
