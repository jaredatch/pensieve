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

    func testParseOriginURLReadsTheOriginTheWayGitDoes() throws {
        try NativeTestWork.run {
            let files = FileService()
            let root = TestTemporaryDirectory.path + "OriginConfig-" + UUID().uuidString
            try files.createDirectory(at: root)
            defer { try? files.deleteDirectory(at: root) }
            for (index, config) in Self.originConfigs.enumerated() {
                let path = root + "/config-\(index)"
                try files.writeFile(at: path, content: config)
                let git = try TestPaths.git.run(["config", "--file", path, "-z", "--get-all", "remote.origin.url"], in: root)
                XCTAssertTrue([0, 1, 128].contains(git.exit), git.stderr)
                let first = git.stdout.split(separator: "\0", omittingEmptySubsequences: false).first.map(String.init)
                let expected = git.exit == 0 && first != "" ? first : nil
                XCTAssertEqual(ProjectIdentityService.parseOriginURL(fromGitConfig: config), expected,
                               "Config \(index): " + config.debugDescription + "\n" + git.stderr)
            }
        }
    }

    private static var originConfigs: [String] {
    let origin = "[remote \"origin\"]\n"
    let url = "https://h/o/r.git"
    return [
        origin + "\turl = " + url + "\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n",
        "[Remote \"origin\"]\nurl = " + url,
        "[remote \"Origin\"]\nurl = " + url,
        "[remote.Origin]\nurl = " + url,
        "[remote \"ori\\gin\"]\nurl = " + url,
        "[remote \"or\\\"igin\"]\nurl = " + url,
        "[remote \"ori\\\\gin\"]\nurl = " + url,
        origin + "url = " + url + " # note",
        origin + "url = " + url + " ; note",
        origin + #"url = "https://h/o/r\"x.git""#,
        origin + #"url = "https://h/o/r\\x.git""#,
        origin + "url = https://h/o/\\\nr.git\n",
        "[remote \"origin\"] url = " + url,
        origin + "url\nurl = " + url,
        origin + "url =\nurl = " + url,
        origin + "url = \"\"\nurl = " + url,
        origin + "url = " + url + "\nurl = https://other/owner/repo.git",
        origin + "pushurl = https://push/owner/repo.git\nurl = " + url,
        origin + "url = " + url + "\n[broken header]\n",
        "[broken header]\n" + origin + "url = " + url,
        "\u{FEFF}" + origin + "URL = " + url,
        "[ReMoTe.Origin]\r\n\tURL = " + url + "\r\n",
        origin + "url = \"https://h/\"o/r.git # note",
        origin + "url = \"https://h/o/#r; x.git\"",
        origin + "url = \"https://h/o/r\\tx\\ny\\bz.git\"",
        origin + "url = " + url + "\nkey = \\\ncontinued",
        origin + "url = " + url + "\nkey = \"unterminated",
        origin + "url = " + url + "\nkey = bad\\escape",
        "orphan = value\n" + origin + "url = " + url,
        "[remote \"upstream\"]\nurl = " + url,
        origin + "fetch = +refs/heads/*:refs/remotes/origin/*",
        ""
    ]
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
