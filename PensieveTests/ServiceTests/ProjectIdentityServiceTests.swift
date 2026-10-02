import XCTest
@testable import Pensieve

final class ProjectIdentityServiceTests: XCTestCase {
    private var fileService: FileService!
    private var service: ProjectIdentityService!
    private var tempDir: String!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveProjectIdentityTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        service = ProjectIdentityService(fileService: fileService)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testIdentityReturnsRemoteForGitDirectoryWithOriginRemote() throws {
        let projectPath = tempDir + "/git-project"
        try fileService.createDirectory(at: projectPath + "/.git")
        try fileService.writeFile(
            at: projectPath + "/.git/config",
            content: """
            [remote "origin"]
                url = git@github.com:owner/repo.git
            """
        )

        let identity = try service.identity(forProjectAt: projectPath)

        XCTAssertEqual(identity, ProjectIdentity(kind: .remote, key: "github.com/owner/repo"))
    }

    func testIdentityUsesMarkerForGitFileWorktreeStyleDirectory() throws {
        let projectPath = tempDir + "/worktree-project"
        try fileService.createDirectory(at: projectPath)
        try fileService.writeFile(at: projectPath + "/.git", content: "gitdir: /somewhere")

        let identity = try service.identity(forProjectAt: projectPath)

        XCTAssertEqual(identity.kind, .marker)
        XCTAssertNotNil(UUID(uuidString: identity.key))
    }

    func testIdentityReturnsExistingMarkerUUID() throws {
        let projectPath = tempDir + "/marked-project"
        let uuid = "11111111-2222-3333-4444-555555555555"
        try fileService.writeFile(
            at: projectPath + "/.pensieve-project",
            content: """
            # Pensieve project identity
            id = \(uuid)
            format_version = 1
            """
        )

        let identity = try service.identity(forProjectAt: projectPath)

        XCTAssertEqual(identity, ProjectIdentity(kind: .marker, key: uuid))
    }

    func testIdentityCreatesMarkerAndReusesItForEmptyDirectory() throws {
        let projectPath = tempDir + "/empty-project"
        try fileService.createDirectory(at: projectPath)

        let first = try service.identity(forProjectAt: projectPath)
        let markerPath = projectPath + "/.pensieve-project"
        let markerText = try fileService.readFile(at: markerPath)
        let second = try service.identity(forProjectAt: projectPath)

        XCTAssertEqual(first.kind, .marker)
        XCTAssertTrue(fileService.fileExists(at: markerPath))
        XCTAssertEqual(ProjectIdentityService.parseMarkerID(from: markerText), first.key)
        XCTAssertEqual(second, first)
    }

    func testPeekIdentityReturnsNilAndDoesNotCreateMarkerForPlainDirectory() throws {
        let projectPath = tempDir + "/peek-plain"
        try fileService.createDirectory(at: projectPath)

        let identity = service.peekIdentity(forProjectAt: projectPath)

        XCTAssertNil(identity)
        XCTAssertFalse(fileService.fileExists(at: projectPath + "/.pensieve-project"))
    }

    func testPeekIdentityReturnsExistingMarkerWithoutRewrite() throws {
        let projectPath = tempDir + "/peek-marked"
        let uuid = "11111111-2222-3333-4444-555555555555"
        let original = """
        # Pensieve project identity
        id = \(uuid)
        format_version = 1
        """
        try fileService.writeFile(at: projectPath + "/.pensieve-project", content: original)

        let identity = service.peekIdentity(forProjectAt: projectPath)
        let after = try fileService.readFile(at: projectPath + "/.pensieve-project")

        XCTAssertEqual(identity, ProjectIdentity(kind: .marker, key: uuid))
        XCTAssertEqual(after, original)
    }

    func testPeekIdentityReturnsRemoteForGitDirectory() throws {
        let projectPath = tempDir + "/peek-git"
        try fileService.createDirectory(at: projectPath + "/.git")
        try fileService.writeFile(
            at: projectPath + "/.git/config",
            content: """
            [remote "origin"]
                url = git@github.com:owner/repo.git
            """
        )

        let identity = service.peekIdentity(forProjectAt: projectPath)

        XCTAssertEqual(identity, ProjectIdentity(kind: .remote, key: "github.com/owner/repo"))
    }
}
