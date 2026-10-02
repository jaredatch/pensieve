import XCTest
@testable import Pensieve

extension ManifestServiceTests {
    private func writeBareInstalledTree(schemaVersion: Int) throws {
        try fileService.createDirectory(at: tempDir + "/manifest/skills")
        try fileService.writeFile(
            at: tempDir + "/manifest/manifest.yaml",
            content: "schema_version: \(schemaVersion)\n"
        )
        try fileService.writeFile(
            at: tempDir + "/manifest/skills/installed.yaml",
            content: """
            slug: installed
            created_at: "2026-07-30T16:00:00Z"
            scope: user
            tags:
            agents:
            origin:
              kind: installed

            """
        )
    }

    func testInstalledOriginRoundTrip() throws {
        let installedDate = try XCTUnwrap(ManifestService.parseDate("2026-07-30T16:00:00Z"))
        let installed = InstalledOrigin(
            repo: "https://github.com/anthropics/skills",
            path: "skills/pdf",
            ref: "main",
            installedCommit: "0f4c9a1e",
            installedTree: "8a1b2c3d",
            contentHash: "sha256:abc123",
            installedAt: installedDate,
            updatedAt: installedDate
        )
        let overlay = SkillOverlay(
            slug: "pdf",
            createdAt: installed.installedAt,
            scope: .user,
            tags: [],
            cursor: nil,
            agents: [],
            origin: .installed(installed)
        )
        try service.write(
            ManifestSnapshot(
                schemaVersion: ManifestService.currentSchemaVersion,
                categories: [],
                scenarios: [],
                projects: [],
                skills: [overlay]
            ),
            toRoot: tempDir
        )

        let raw = try fileService.readFile(at: tempDir + "/manifest/skills/pdf.yaml")
        let expectedOrigin = """
        origin:
          kind: installed
          repo: "https://github.com/anthropics/skills"
          path: "skills/pdf"
          ref: "main"
          installed_commit: "0f4c9a1e"
          installed_tree: "8a1b2c3d"
          content_hash: "sha256:abc123"
          installed_at: "2026-07-30T16:00:00.000Z"
          updated_at: "2026-07-30T16:00:00.000Z"
        """
        XCTAssertTrue(raw.contains(expectedOrigin), raw)
        XCTAssertEqual(try service.read(fromRoot: tempDir).skills.first?.origin, .installed(installed))
    }

    func testPartialInstalledOriginCollapsesToEmpty() throws {
        try fileService.createDirectory(at: tempDir + "/manifest/skills")
        try fileService.writeFile(
            at: tempDir + "/manifest/manifest.yaml",
            content: "schema_version: 3\n"
        )
        try fileService.writeFile(
            at: tempDir + "/manifest/skills/partial.yaml",
            content: """
            slug: partial
            created_at: "2026-07-30T16:00:00Z"
            scope: user
            tags:
            agents:
            origin:
              kind: installed
              repo: "https://github.com/anthropics/skills"
              path: "skills/pdf"

            """
        )

        // A mixed partial block (some keys present, others missing) must collapse to the fully-empty
        // origin, not a half-linked record carrying just the keys that survived.
        XCTAssertEqual(
            try service.read(fromRoot: tempDir).skills.first?.origin,
            .installed(.empty)
        )
    }

    func testVersionThreeInstalledOriginMissingCoordinatesReadsEmpty() throws {
        try writeBareInstalledTree(schemaVersion: 3)

        XCTAssertEqual(
            try service.read(fromRoot: tempDir).skills.first?.origin,
            .installed(.empty)
        )
    }

    func testVersionTwoInstalledOriginReadsEmpty() throws {
        try writeBareInstalledTree(schemaVersion: 2)
        let read = try service.read(fromRoot: tempDir)

        XCTAssertEqual(read.schemaVersion, 2)
        XCTAssertEqual(read.skills.first?.origin, .installed(.empty))
    }

    func testWriteUpgradesVersionTwoTreeToVersionFive() throws {
        try writeBareInstalledTree(schemaVersion: 2)
        let versionTwo = try service.read(fromRoot: tempDir)

        try service.write(versionTwo, toRoot: tempDir)

        XCTAssertEqual(
            try fileService.readFile(at: tempDir + "/manifest/manifest.yaml"),
            "schema_version: 5\n"
        )
        XCTAssertEqual(try service.read(fromRoot: tempDir).skills.first?.origin, .installed(.empty))
    }

    func testVersionTwoWriterRefusesVersionFiveTree() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let beforeAnchor = try fileService.readFile(at: tempDir + "/manifest/manifest.yaml")
        let beforeSkill = try fileService.readFile(at: tempDir + "/manifest/skills/plain.yaml")
        let versionTwoWriter = ManifestService(fileService: fileService, supportedSchemaVersion: 2)

        XCTAssertThrowsError(
            try versionTwoWriter.write(sampleManifestSnapshot(), toRoot: tempDir)
        ) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedSchema(found: 5, supported: 2))
        }
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/manifest.yaml"), beforeAnchor)
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/skills/plain.yaml"), beforeSkill)
    }
}
