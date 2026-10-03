import XCTest
import Yams
@testable import Pensieve

extension ManifestServiceTests {
    private func installedOverlay(slug: String, path: String) throws -> SkillOverlay {
        let date = try XCTUnwrap(ManifestService.parseDate("2026-07-30T16:00:00Z"))
        return SkillOverlay(
            slug: slug,
            createdAt: date,
            scope: .user,
            tags: [],
            cursor: nil,
            agents: [],
            origin: .installed(InstalledOrigin(
                repo: "https://github.com/anthropics/skills",
                path: path,
                ref: "main",
                installedCommit: "0f4c9a1e",
                installedTree: "8a1b2c3d",
                contentHash: "sha256:abc123",
                installedAt: date,
                updatedAt: date
            ))
        )
    }

    private func write(_ overlay: SkillOverlay) throws {
        try service.write(
            ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                             categories: [], projects: [], skills: [overlay]),
            toRoot: tempDir
        )
    }

    // A hostile repo directory name carries the break/control character into origin.path (only the
    // slug is sanitized). The serializer must escape it so the manifest still parses and the exact
    // path round-trips — an unescaped CR/NEL/LS/PS would break the quoted scalar and permanently
    // brick every manifest read (install/adopt/update/sync/rebuild). (PLAN-19 security review.)
    func testInstalledOriginPathWithControlCharsRoundTrips() throws {
        // Covers C0 (\0, \r, \u{01}), DEL (\u{7F}), the FULL C1 range (\u{80}, \u{85} NEL, \u{9F}),
        // and the two extra YAML-1.1 breaks (LS \u{2028}, PS \u{2029}).
        let hostilePath =
            "skills/evil\r---\rx\u{7F}\u{80}\u{85}\u{9F}\u{2028}\u{2029}\u{0}\u{01}tail"
        try write(try installedOverlay(slug: "evil-x", path: hostilePath))

        // The written file must be valid YAML (no raw break inside the quoted scalar)...
        let raw = try fileService.readFile(at: tempDir + "/manifest/skills/evil-x.yaml")
        XCTAssertNoThrow(try Yams.load(yaml: raw))

        // ...and the path must survive byte-for-byte through a full read.
        let readBack = try service.read(fromRoot: tempDir)
        guard case let .installed(origin)? = readBack.skills.first?.origin else {
            return XCTFail("expected an installed origin")
        }
        XCTAssertEqual(origin.path, hostilePath)
    }

    // A path-safe but non-canonical slug (an imported/hand-placed `PDF_Tools` dir — a
    // ~/.claude/skills bootstrap case) must round-trip through the full-snapshot writer, NOT throw
    // corruptManifestFile. The canonical-strict guard bricked every write on one such row.
    func testPathSafeNonCanonicalSlugSurvivesWrite() throws {
        XCTAssertFalse(SkillStore.isCanonicalSlug("PDF_Tools"))
        XCTAssertNoThrow(try write(try installedOverlay(slug: "PDF_Tools", path: "skills/pdf")))
        let readBack = try service.read(fromRoot: tempDir)
        XCTAssertEqual(readBack.skills.first?.slug, "PDF_Tools")
    }

    // Two slugs differing only in case map to the same skills/<slug>.yaml on a case-insensitive
    // volume (default APFS); admitting both would silently drop one overlay on write. Case-folded
    // dedup must surface it as corruption. (Regression for the relaxation that first admitted
    // mixed-case slugs.)
    func testCaseCollidingSlugsRejected() throws {
        let snapshot = ManifestSnapshot(
            schemaVersion: ManifestService.currentSchemaVersion,
            categories: [], projects: [],
            skills: [try installedOverlay(slug: "PDF_Tools", path: "skills/a"),
                     try installedOverlay(slug: "pdf_tools", path: "skills/b")]
        )
        XCTAssertThrowsError(try service.write(snapshot, toRoot: tempDir)) { error in
            XCTAssertEqual(error as? ManifestError, .corruptManifestFile("skills/pdf_tools.yaml"))
        }
    }

    // Traversal is still rejected — the security guarantee (a slug can't escape skills/ as a
    // filename) survives the relaxation from canonical to path-safe.
    func testPathUnsafeSlugStillRejected() throws {
        for unsafe in ["../evil", "a/b", ".hidden", "with\u{0}nul"] {
            XCTAssertThrowsError(try write(try installedOverlay(slug: unsafe, path: "skills/pdf")),
                                 "expected \(unsafe) to be rejected") { error in
                XCTAssertEqual(error as? ManifestError, .corruptManifestFile("skills/" + unsafe + ".yaml"))
            }
        }
    }
}
