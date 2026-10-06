import XCTest
@testable import Pensieve

func sampleManifestSnapshot() -> ManifestSnapshot {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return ManifestSnapshot(
        schemaVersion: ManifestService.currentSchemaVersion,
        categories: [
            CategoryRecord(
                name: "Swift",
                projectKeys: ["git:github.com/me/b", "git:github.com/me/a"],
                skillSlugs: ["swiftui-review", "swift-style"]
            ),
            CategoryRecord(name: "../evil/../name", projectKeys: [], skillSlugs: [])
        ],

        projects: [
            ProjectIdentityRecord(identityKey: "git:github.com/me/a", identityKind: "remote", name: "App A"),
            ProjectIdentityRecord(identityKey: "marker:/tmp/b", identityKind: "marker", name: "App B")
        ],
        skills: [
            SkillOverlay(
                slug: "swift-style",
                createdAt: date,
                scope: .user,
                tags: ["review", "swift"],
                cursor: CursorAdapterConfig(description: "Swift: rules", globs: ["**/*.swift"], alwaysApply: false),
                agents: [],
                origin: .imported(from: "claude-code")
            ),
            SkillOverlay(
                slug: "plain",
                createdAt: date,
                scope: .project,
                tags: [],
                cursor: nil,
                agents: [],
                origin: .authored
            )
        ]
    )
}

private func normalizedManifestSnapshot(_ snapshot: ManifestSnapshot) -> ManifestSnapshot {
    ManifestSnapshot(
        schemaVersion: snapshot.schemaVersion,
        categories: snapshot.categories.map {
            CategoryRecord(
                name: $0.name,
                projectKeys: Array(Set($0.projectKeys)).sorted(),
                skillSlugs: Array(Set($0.skillSlugs)).sorted()
            )
        }.sorted { $0.name < $1.name },
        projects: snapshot.projects.sorted { $0.identityKey < $1.identityKey },
        skills: snapshot.skills.map {
            SkillOverlay(
                slug: $0.slug,
                createdAt: $0.createdAt,
                scope: $0.scope,
                tags: Array(Set($0.tags)).sorted(),
                cursor: $0.cursor.map {
                    CursorAdapterConfig(
                        description: $0.description,
                        globs: $0.globs.map { Array(Set($0)).sorted() },
                        alwaysApply: $0.alwaysApply
                    )
                },
                agents: Array(Set($0.agents)).sorted(),
                origin: $0.origin
            )
        }.sorted { $0.slug < $1.slug }
    )
}

final class ManifestServiceTests: XCTestCase {
    var tempDir: String!
    var fileService: FileService!
    var service: ManifestService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveManifestTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        service = ManifestService(fileService: fileService)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    private func categoryPath(named name: String) throws -> String {
        let categoryDir = tempDir + "/manifest/categories"
        let categoryFile = try XCTUnwrap(try fileService.listDirectory(at: categoryDir).first {
            try fileService.readFile(at: categoryDir + "/" + $0).contains("name: \(SkillSerializer.quotedScalar(name))")
        })
        return categoryDir + "/" + categoryFile
    }

    private func assertCorruptManifestRead(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try service.read(fromRoot: tempDir), file: file, line: line) { error in
            guard case ManifestError.corruptManifestFile = error else {
                return XCTFail("expected corruptManifestFile, got \(error)", file: file, line: line)
            }
        }
    }

    func testRoundTripReproducesSnapshot() throws {
        let snapshot = sampleManifestSnapshot()
        try service.write(snapshot, toRoot: tempDir)
        let read = try service.read(fromRoot: tempDir)
        XCTAssertEqual(read, normalizedManifestSnapshot(snapshot))
    }

    func testCreatedAtRoundTripsWithFractionalSeconds() throws {
        // A real SwiftData `Date()` carries sub-second precision; it must survive write -> read.
        // (Regression for PLAN-07 / 07.3 review: a whole-second-only formatter truncated it to .000.)
        let fractional = Date(timeIntervalSince1970: 1_700_000_000.123)
        let snapshot = ManifestSnapshot(
            schemaVersion: 1,
            categories: [],

            projects: [],
            skills: [SkillOverlay(slug: "frac", createdAt: fractional, scope: .user, tags: [],
                                  cursor: nil, agents: [], origin: .authored)]
        )
        try service.write(snapshot, toRoot: tempDir)
        let overlay = try XCTUnwrap(try service.read(fromRoot: tempDir).skills.first { $0.slug == "frac" })
        XCTAssertEqual(overlay.createdAt.timeIntervalSince1970, 1_700_000_000.123, accuracy: 0.0005)
    }

    func testLayoutIsPerEntityWithOneItemPerLine() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let categoryDir = tempDir + "/manifest/categories"
        let files = try fileService.listDirectory(at: categoryDir).filter { $0.hasSuffix(".yaml") }
        let swiftFile = try XCTUnwrap(files.first {
            try fileService.readFile(at: categoryDir + "/" + $0).contains("name: Swift")
        })
        let content = try fileService.readFile(at: categoryDir + "/" + swiftFile)
        XCTAssertTrue(content.contains("\n  - "))
        XCTAssertFalse(content.contains("["))
        XCTAssertTrue(content.range(of: "swift-style")!.lowerBound < content.range(of: "swiftui-review")!.lowerBound)
    }

    func testDuplicateListLinesDedupOnRead() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let path = tempDir + "/manifest/skills/swift-style.yaml"
        var raw = try fileService.readFile(at: path)
        raw = raw.replacingOccurrences(of: "tags:\n  - review", with: "tags:\n  - review\n  - review")
        try fileService.writeFile(at: path, content: raw)
        let read = try service.read(fromRoot: tempDir)
        let overlay = try XCTUnwrap(read.skills.first { $0.slug == "swift-style" })
        XCTAssertEqual(overlay.tags, ["review", "swift"])
    }

    func testProjectDedupDeterministicWinner() throws {
        // Two records share an identity_key with DIFFERENT names (a merge=union artifact). read() must
        // collapse them to ONE — the lexicographically-first (name, identity_kind) — deterministically.
        let snapshot = ManifestSnapshot(
            schemaVersion: 1,
            categories: [],

            projects: [
                ProjectIdentityRecord(identityKey: "github.com/x/y", identityKind: "remote", name: "App B"),
                ProjectIdentityRecord(identityKey: "github.com/x/y", identityKind: "remote", name: "App A")
            ],
            skills: []
        )
        try service.write(snapshot, toRoot: tempDir)
        let projects = try service.read(fromRoot: tempDir).projects.filter { $0.identityKey == "github.com/x/y" }
        XCTAssertEqual(projects.count, 1, "duplicate identity_key collapses to exactly one record")
        XCTAssertEqual(projects.first?.name, "App A", "winner = lexicographically-first (name, identity_kind)")
    }

    func testProjectFlowMapRoundTripsSpecialCharacters() throws {
        // flowQuoted must keep a project record parseable inside a YAML flow map even when a field carries
        // flow indicators / escapes — proving the always-double-quote (not quotedScalar's block rules).
        let tricky = ProjectIdentityRecord(
            identityKey: "github.com/x/y",
            identityKind: "remote",
            name: "A, {weird} \"name\" with \\ and\ttab\nnewline"
        )
        let snapshot = ManifestSnapshot(schemaVersion: 1, categories: [], projects: [tricky], skills: [])
        try service.write(snapshot, toRoot: tempDir)
        let read = try service.read(fromRoot: tempDir).projects
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first, tricky, "special-char project name round-trips through the flow map")
    }

    func testBlankProjectsYamlReadsAsNoProjects() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        try fileService.writeFile(at: tempDir + "/manifest/projects.yaml", content: "  \n\t\n")
        XCTAssertTrue(try service.read(fromRoot: tempDir).projects.isEmpty)
    }

    func testSerializedCategoryAndProjectsOmitSchemaVersion() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let categoryDir = tempDir + "/manifest/categories"
        let categoryFile = try XCTUnwrap(try fileService.listDirectory(at: categoryDir).first { $0.hasSuffix(".yaml") })
        XCTAssertFalse(try fileService.readFile(at: categoryDir + "/" + categoryFile).contains("schema_version"))
        XCTAssertFalse(try fileService.readFile(at: tempDir + "/manifest/projects.yaml").contains("schema_version"))
        XCTAssertFalse(try fileService.readFile(at: tempDir + "/manifest/skills/swift-style.yaml").contains("schema_version"))
        XCTAssertTrue(try fileService.readFile(at: tempDir + "/manifest/manifest.yaml").contains("schema_version"))
    }

    func testReadThrowsOnCorruptManifestYaml() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: not-an-int\n")
        XCTAssertThrowsError(try service.read(fromRoot: tempDir)) { error in
            guard case ManifestError.corruptManifestFile = error else {
                return XCTFail("expected corruptManifestFile, got \(error)")
            }
        }
    }

    func testReadThrowsOnCorruptCategoryFile() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let categoryDir = tempDir + "/manifest/categories"
        let categoryFile = try XCTUnwrap(try fileService.listDirectory(at: categoryDir).first { $0.hasSuffix(".yaml") })
        try fileService.writeFile(at: categoryDir + "/" + categoryFile, content: ":\n  - [\n")
        assertCorruptManifestRead()
    }

    func testReadThrowsOnScalarCategoryMembershipFields() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let swiftCategoryPath = try categoryPath(named: "Swift")
        var raw = try fileService.readFile(at: swiftCategoryPath)
        raw = raw.replacingOccurrences(of: "skill_slugs:\n  - swift-style\n  - swiftui-review", with: "skill_slugs: swift-style")
        try fileService.writeFile(at: swiftCategoryPath, content: raw)
        assertCorruptManifestRead()

        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        raw = try fileService.readFile(at: swiftCategoryPath)
        raw = raw.replacingOccurrences(
            of: "project_keys:\n  - git:github.com/me/a\n  - git:github.com/me/b",
            with: "project_keys: git:github.com/me/a"
        )
        try fileService.writeFile(at: swiftCategoryPath, content: raw)
        assertCorruptManifestRead()
    }

    func testReadThrowsOnScalarSkillOverlayMembershipField() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let path = tempDir + "/manifest/skills/swift-style.yaml"
        var raw = try fileService.readFile(at: path)
        raw = raw.replacingOccurrences(of: "tags:\n  - review\n  - swift", with: "tags: review")
        try fileService.writeFile(at: path, content: raw)
        assertCorruptManifestRead()
    }

    func testReadThrowsOnScalarSkillOverlayAgentsField() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let path = tempDir + "/manifest/skills/swift-style.yaml"
        var raw = try fileService.readFile(at: path)
        raw = raw.replacingOccurrences(of: "agents:", with: "agents: claude")
        XCTAssertTrue(raw.contains("agents: claude"))
        try fileService.writeFile(at: path, content: raw)
        assertCorruptManifestRead()
    }

    func testReadThrowsOnNonStringMembershipElement() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let swiftCategoryPath = try categoryPath(named: "Swift")
        var raw = try fileService.readFile(at: swiftCategoryPath)
        raw = raw.replacingOccurrences(
            of: "skill_slugs:\n  - swift-style\n  - swiftui-review",
            with: "skill_slugs:\n  - 123"
        )
        try fileService.writeFile(at: swiftCategoryPath, content: raw)
        assertCorruptManifestRead()
    }

    func testAbsentMembershipKeyReadsEmptySet() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let swiftCategoryPath = try categoryPath(named: "Swift")
        let raw = """
        name: Swift
        project_keys:
          - git:github.com/me/a
          - git:github.com/me/b

        """
        try fileService.writeFile(at: swiftCategoryPath, content: raw)
        let category = try XCTUnwrap(try service.read(fromRoot: tempDir).categories.first { $0.name == "Swift" })
        XCTAssertEqual(category.skillSlugs, [])
    }

    func testSerializedEmptyMembershipCategoryReadsAsEmptySet() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let category = try XCTUnwrap(
            try service.read(fromRoot: tempDir).categories.first { $0.name == "../evil/../name" }
        )
        XCTAssertEqual(category.projectKeys, [])
        XCTAssertEqual(category.skillSlugs, [])
    }

    func testEmptyRootReadsEmptySnapshot() throws {
        let read = try service.read(fromRoot: tempDir)
        XCTAssertTrue(read.categories.isEmpty)
        XCTAssertTrue(read.projects.isEmpty)
        XCTAssertTrue(read.skills.isEmpty)
    }

    func testNewerSchemaThrows() throws {
        try fileService.createDirectory(at: tempDir + "/manifest")
        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: 999\n")
        XCTAssertThrowsError(try service.read(fromRoot: tempDir)) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedSchema(found: 999, supported: 5))
        }
    }

    func testCategoryFilenamesArePathSafe() {
        for name in ["a/b", "../../etc/passwd", "..", "", "日本語", "😀"] {
            let filename = ManifestService.categoryFileName(name)
            XCTAssertFalse(filename.contains("/"), "\(name) -> \(filename)")
            XCTAssertFalse(filename.contains(".."), "\(name) -> \(filename)")
            XCTAssertTrue(filename.hasSuffix(".yaml"))
        }
        XCTAssertTrue(ManifestService.categoryFileName("日本語").hasPrefix("cat-"))
        XCTAssertTrue(ManifestService.categoryFileName("").hasPrefix("cat-"))
    }

    func testDistinctNamesSameSlugGetDistinctFiles() {
        XCTAssertNotEqual(ManifestService.categoryFileName("Swift!"), ManifestService.categoryFileName("Swift?"))
    }

    func testTraversalNameStaysUnderCategoriesAndKeysByInFileName() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let categoryDir = tempDir + "/manifest/categories"
        let files = try fileService.listDirectory(at: categoryDir)
        XCTAssertEqual(files.count, 2)
        let read = try service.read(fromRoot: tempDir)
        XCTAssertTrue(read.categories.contains { $0.name == "../evil/../name" })
    }
}
