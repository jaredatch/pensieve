import XCTest
@testable import Pensieve

final class SkillInstallURLTests: XCTestCase {
    func testSchemelessGitHubRepoIsAccepted() {
        XCTAssertEqual(
            SkillInstallURL.parse("github.com/jaredatch/pensieve-skills"),
            SkillInstallURL.parse("https://github.com/jaredatch/pensieve-skills")
        )
        // The rewrite prefixes the ORIGINAL string (case-folded compare, spelling preserved): a
        // mixed-case ref/path must survive exactly as the explicit https form keeps it.
        XCTAssertEqual(
            SkillInstallURL.parse("github.com/Owner/Repo/tree/Feature/Skill"),
            SkillInstallURL.parse("https://github.com/Owner/Repo/tree/Feature/Skill")
        )
    }

    func testSchemelessWwwGitHubIsCanonicalized() {
        XCTAssertEqual(
            SkillInstallURL.parse("www.github.com/o/r"),
            SkillInstallURL.parse("https://github.com/o/r")
        )
    }

    func testSchemelessNonGitHubHostStaysRejected() {
        XCTAssertEqual(SkillInstallURL.parseResult("gitlab.com/o/r"), .failure(.unsupportedURL))
    }

    func testHttpSchemeStaysRejected() {
        XCTAssertEqual(SkillInstallURL.parseResult("http://github.com/o/r"), .failure(.unsupportedURL))
    }

    func testSchemelessPathTrickStaysRejected() {
        XCTAssertEqual(SkillInstallURL.parseResult("evil.com/github.com/o/r"), .failure(.unsupportedURL))
    }

    func testShorthandLookalikeHostsStayRejected() {
        XCTAssertEqual(SkillInstallURL.parseResult("www.github.com.evil/o/r"), .failure(.unsupportedURL))
        XCTAssertEqual(SkillInstallURL.parseResult("github.com.evil/o/r"), .failure(.unsupportedURL))
        // Exact-prefix boundary: the shorthand must be the START of the input, not merely contained.
        XCTAssertEqual(SkillInstallURL.parseResult("xxwww.github.com/o/r"), .failure(.unsupportedURL))
        XCTAssertEqual(SkillInstallURL.parseResult("xxwww.github.com/repo"), .failure(.unsupportedURL))
        XCTAssertEqual(SkillInstallURL.parseResult("xgithub.com/o/r"), .failure(.unsupportedURL))
    }

    func testShorthandKeepsHardeningRejections() {
        let rejected = [
            "github.com/o/r?x=1",
            "github.com/o/r#f",
            "github.com:8080/o/r",
            "user@github.com/o/r"
        ]

        for input in rejected {
            XCTAssertEqual(SkillInstallURL.parseResult(input), .failure(.unsupportedURL))
        }
    }

    func testParsesRepositoryFormWithReconstructedCloneRemote() {
        let parsed = SkillInstallURL.parse("https://github.com/anthropics/skills")

        XCTAssertEqual(parsed?.repo, "https://github.com/anthropics/skills")
        XCTAssertEqual(parsed?.cloneRemote, "https://github.com/anthropics/skills.git")
        XCTAssertNil(parsed?.ref)
        XCTAssertNil(parsed?.path)
        XCTAssertEqual(parsed?.form, .repo)
    }

    func testNormalizesRepositoryWhitespaceTrailingSlashAndDotGit() {
        let parsed = SkillInstallURL.parse(" \n https://github.com/anthropics/skills.git/ \t")

        XCTAssertEqual(parsed?.repo, "https://github.com/anthropics/skills")
        XCTAssertEqual(parsed?.cloneRemote, "https://github.com/anthropics/skills.git")
        XCTAssertEqual(parsed?.form, .repo)
    }

    func testParsesTreeForm() {
        let parsed = SkillInstallURL.parse(
            "https://github.com/anthropics/skills/tree/release-1/skills/pdf/"
        )

        XCTAssertEqual(parsed?.repo, "https://github.com/anthropics/skills")
        XCTAssertEqual(parsed?.ref, "release-1")
        XCTAssertEqual(parsed?.path, "skills/pdf")
        XCTAssertEqual(parsed?.form, .tree)
    }

    func testParsesBlobFormAndUsesParentDirectory() {
        let parsed = SkillInstallURL.parse(
            "https://github.com/anthropics/skills/blob/main/skills/pdf/SKILL.md"
        )

        XCTAssertEqual(parsed?.repo, "https://github.com/anthropics/skills")
        XCTAssertEqual(parsed?.ref, "main")
        XCTAssertEqual(parsed?.path, "skills/pdf")
        XCTAssertEqual(parsed?.form, .blob)
    }

    func testParsesRootSkillBlobWithEmptyParentPath() {
        let parsed = SkillInstallURL.parse(
            "https://github.com/owner/root-skill/blob/main/SKILL.md"
        )

        XCTAssertEqual(parsed?.path, "")
        XCTAssertEqual(parsed?.form, .blob)
    }

    func testTreeAndBlobFormsResolveIdentically() {
        let tree = SkillInstallURL.parse(
            "https://github.com/anthropics/skills/tree/main/skills/pdf"
        )
        let blob = SkillInstallURL.parse(
            "https://github.com/anthropics/skills/blob/main/skills/pdf/SKILL.md"
        )

        XCTAssertEqual(tree?.repo, blob?.repo)
        XCTAssertEqual(tree?.ref, blob?.ref)
        XCTAssertEqual(tree?.path, blob?.path)
        XCTAssertEqual(tree?.repo, "https://github.com/anthropics/skills")
        XCTAssertEqual(tree?.ref, "main")
        XCTAssertEqual(tree?.path, "skills/pdf")
    }

    func testPercentDecodesRefAndPathSegments() {
        let parsed = SkillInstallURL.parse(
            "https://github.com/owner/repo/tree/release%2D1/skills/my%20skill"
        )

        XCTAssertEqual(parsed?.ref, "release-1")
        XCTAssertEqual(parsed?.path, "skills/my skill")
    }

    func testSlashNamedBranchUsesFirstSegmentAsRef() {
        let parsed = SkillInstallURL.parse(
            "https://github.com/owner/repo/tree/feature/pdf/skills/example"
        )

        XCTAssertEqual(parsed?.ref, "feature")
        XCTAssertEqual(parsed?.path, "pdf/skills/example")
    }

    func testRejectsNonHTTPS() {
        XCTAssertNil(SkillInstallURL.parse("http://github.com/owner/repo"))
        XCTAssertNil(SkillInstallURL.parse("ssh://github.com/owner/repo"))
    }

    func testRejectsNonGitHubHostAndSubdomains() {
        XCTAssertNil(SkillInstallURL.parse("https://example.com/owner/repo"))
        XCTAssertNil(SkillInstallURL.parse("https://gist.github.com/owner/repo"))
        XCTAssertNil(SkillInstallURL.parse("https://raw.githubusercontent.com/owner/repo"))
    }

    func testRejectsUserInfo() {
        XCTAssertNil(SkillInstallURL.parse("https://user@github.com/owner/repo"))
        XCTAssertNil(SkillInstallURL.parse("https://user:token@github.com/owner/repo"))
    }

    func testRejectsExplicitPort() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com:443/owner/repo"))
    }

    func testRejectsEmptyPortAuthority() {
        // URLComponents reports the bare port delimiter as port == nil, so the authority check
        // itself must catch it.
        XCTAssertNil(SkillInstallURL.parse("https://github.com:/owner/repo"))
    }

    func testRejectsNonASCIIOwnerOrRepository() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/ownér/repo"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/répo"))
    }

    func testRejectsEmptyOwnerOrRepository() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com//repo"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/.git"))
    }

    func testRejectsDotSegmentsBeforeAndAfterPercentDecoding() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main/../skill"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main/%2E%2E/skill"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main/%2E/skill"))
    }

    func testRejectsEmptyInteriorPathComponents() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main//skill"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner//tree/main/skill"))
    }

    func testRejectsNULAndBackslashAfterPercentDecoding() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main/skill%00name"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main/skills%5Cpdf"))
    }

    func testRejectsPercentEncodedSlashInsideComponent() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main/skills%2Fpdf"))
    }

    func testRejectsBlobNotEndingInSkillMarkdown() {
        XCTAssertNil(
            SkillInstallURL.parse("https://github.com/owner/repo/blob/main/skills/pdf/README.md")
        )
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/blob/main/skills/pdf"))
    }

    func testRejectsCommitShaRef() {
        let sha = "0123456789abcdef0123456789ABCDEF01234567"
        let url = "https://github.com/owner/repo/tree/\(sha)/skills/pdf"

        XCTAssertNil(SkillInstallURL.parse(url))
        switch SkillInstallURL.parseResult(url) {
        case .success:
            XCTFail("A commit permalink must not parse")
        case let .failure(error):
            XCTAssertEqual(error, .commitLink)
            XCTAssertEqual(
                error.errorDescription,
                "commit links aren't supported — use a branch link"
            )
        }
    }

    func testRejectsImplausibleRefNames() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/bad..ref/skills/pdf"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/bad%20ref/skills/pdf"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/%2Ehidden/skills/pdf"))
    }

    func testRejectsTreeWithoutSkillPath() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/tree/main/"))
    }

    func testRejectsUnsupportedExtraShapes() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/issues"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo/pull/1"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo.git/tree/main/skill"))
    }

    func testRejectsQueryAndFragment() {
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo?tab=readme"))
        XCTAssertNil(SkillInstallURL.parse("https://github.com/owner/repo#readme"))
    }

    func testUnsupportedURLHasGenericUserFacingMessage() {
        switch SkillInstallURL.parseResult("https://example.com/owner/repo") {
        case .success:
            XCTFail("A non-GitHub host must not parse")
        case let .failure(error):
            XCTAssertEqual(error, .unsupportedURL)
            XCTAssertEqual(error.errorDescription, "not a supported GitHub URL")
        }
    }
}
