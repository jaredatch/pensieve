import XCTest
@testable import Pensieve

final class ProjectIdentityTests: XCTestCase {
    func testNormalizeRemoteURLMatchesArtifactsTable() {
        let cases: [(String, String?)] = [
            ("git@github.com:owner/repo.git", "github.com/owner/repo"),
            ("https://github.com/owner/repo.git", "github.com/owner/repo"),
            ("https://github.com/owner/repo", "github.com/owner/repo"),
            ("https://github.com/owner/repo/", "github.com/owner/repo"),
            ("ssh://git@github.com/owner/repo.git", "github.com/owner/repo"),
            ("git@GitHub.com:owner/repo.git", "github.com/owner/repo"),
            ("https://gitlab.example.com:2222/group/sub/repo.git", "gitlab.example.com/group/sub/repo"),
            ("https://github.com/owner/repo?ref=main#frag", "github.com/owner/repo"),
            ("git@github.com:owner/repo", "github.com/owner/repo"),
            ("https://github.com", nil),
            ("https://github.com/", nil),
            ("git@github.com:", nil),
            ("", nil),
            ("not-a-url", nil)
        ]

        for (input, expected) in cases {
            XCTAssertEqual(ProjectIdentityService.normalizeRemoteURL(input), expected, input)
        }
    }

    func testParseOriginURLReturnsBareURLFromOriginSection() {
        let config = """
        [core]
            repositoryformatversion = 0
        [remote "origin"]
            url = git@github.com:owner/repo.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        """

        XCTAssertEqual(ProjectIdentityService.parseOriginURL(fromGitConfig: config), "git@github.com:owner/repo.git")
    }

    func testParseOriginURLReturnsQuotedURLFromOriginSection() {
        let config = """
        [remote "origin"]
            url = "https://github.com/owner/repo.git"
        """

        XCTAssertEqual(ProjectIdentityService.parseOriginURL(fromGitConfig: config), "https://github.com/owner/repo.git")
    }

    func testParseOriginURLReturnsNilWhenOriginSectionAbsent() {
        let config = """
        [remote "upstream"]
            url = https://github.com/owner/repo.git
        """

        XCTAssertNil(ProjectIdentityService.parseOriginURL(fromGitConfig: config))
    }

    func testParseOriginURLReturnsNilWhenURLKeyAbsent() {
        let config = """
        [remote "origin"]
            fetch = +refs/heads/*:refs/remotes/origin/*
        """

        XCTAssertNil(ProjectIdentityService.parseOriginURL(fromGitConfig: config))
    }

    func testParseMarkerIDReturnsValidUUIDLine() {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let marker = """
        id = \(uuid)
        format_version = 1
        """

        XCTAssertEqual(ProjectIdentityService.parseMarkerID(from: marker), uuid)
    }

    func testParseMarkerIDIgnoresCommentLines() {
        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let marker = """
        # id = not-a-uuid
        # another comment
        id = \(uuid)
        """

        XCTAssertEqual(ProjectIdentityService.parseMarkerID(from: marker), uuid)
    }

    func testParseMarkerIDReturnsNilWhenIDAbsent() {
        XCTAssertNil(ProjectIdentityService.parseMarkerID(from: "format_version = 1"))
    }

    func testParseMarkerIDReturnsNilForNonUUIDID() {
        XCTAssertNil(ProjectIdentityService.parseMarkerID(from: "id = not-a-uuid"))
    }
}
