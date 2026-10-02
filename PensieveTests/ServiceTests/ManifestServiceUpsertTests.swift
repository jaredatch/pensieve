import XCTest
@testable import Pensieve

extension ManifestServiceTests {
    func testUpsertSkillOverlayPreservesUnrelatedEntities() throws {
        let scenarioID = UUID().uuidString
        var snapshot = sampleManifestSnapshot()
        snapshot.scenarios = [
            ScenarioRecord(
                id: scenarioID,
                name: "Release",
                skillSlugs: ["plain"],
                agents: ["codex"]
            )
        ]
        snapshot.deployIntents = [DeployIntentRecord(
            machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            skillSlug: "plain",
            platformRaw: "codex",
            projectKey: "github.com/owner/project"
        )]
        try service.write(snapshot, toRoot: tempDir)
        let before = try unrelatedManifestBytes(excludingSkill: "plain")

        let replacement = SkillOverlay(
            slug: "plain",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            scope: .user,
            tags: ["updated"],
            cursor: nil,
            agents: ["codex"],
            origin: .authored
        )
        try service.upsertSkillOverlay(replacement, toRoot: tempDir)

        XCTAssertEqual(try unrelatedManifestBytes(excludingSkill: "plain"), before)
        XCTAssertEqual(
            try service.read(fromRoot: tempDir).skills.first { $0.slug == "plain" },
            replacement
        )
        XCTAssertEqual(try service.read(fromRoot: tempDir).deployIntents, snapshot.deployIntents)
    }

    func testUpsertSkillOverlayIsIdempotent() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let overlay = SkillOverlay(
            slug: "new-skill",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            scope: .user,
            tags: ["one"],
            cursor: nil,
            agents: [],
            origin: .authored
        )

        try service.upsertSkillOverlay(overlay, toRoot: tempDir)
        let once = try manifestTreeBytes()
        try service.upsertSkillOverlay(overlay, toRoot: tempDir)

        XCTAssertEqual(try manifestTreeBytes(), once)
        XCTAssertEqual(
            try service.read(fromRoot: tempDir).skills.filter { $0.slug == "new-skill" }.count,
            1
        )
    }

    func testUpsertSkillOverlaySurfacesCorruptManifest() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        try fileService.writeFile(
            at: tempDir + "/manifest/skills/plain.yaml",
            content: "slug: [not-a-scalar]\n"
        )
        let overlay = SkillOverlay(
            slug: "new-skill",
            createdAt: Date(),
            scope: .user,
            tags: [],
            cursor: nil,
            agents: [],
            origin: .authored
        )

        XCTAssertThrowsError(try service.upsertSkillOverlay(overlay, toRoot: tempDir)) { error in
            XCTAssertEqual(
                error as? ManifestError,
                .corruptManifestFile("skills/plain.yaml")
            )
        }
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/manifest/skills/new-skill.yaml"))
    }

    func testUpsertRejectsPathBearingSlugReadFromManifest() throws {
        try service.write(sampleManifestSnapshot(), toRoot: tempDir)
        let path = tempDir + "/manifest/skills/plain.yaml"
        let original = try fileService.readFile(at: path)
        try fileService.writeFile(
            at: path,
            content: original.replacingOccurrences(of: "slug: plain", with: "slug: ../manifest")
        )
        let overlay = SkillOverlay(
            slug: "new-skill",
            createdAt: Date(),
            scope: .user,
            tags: [],
            cursor: nil,
            agents: [],
            origin: .authored
        )

        XCTAssertThrowsError(try service.upsertSkillOverlay(overlay, toRoot: tempDir)) { error in
            XCTAssertEqual(
                error as? ManifestError,
                .corruptManifestFile("skills/../manifest.yaml")
            )
        }
        XCTAssertEqual(try fileService.readFile(at: path), original.replacingOccurrences(
            of: "slug: plain",
            with: "slug: ../manifest"
        ))
        XCTAssertFalse(fileService.fileExists(at: tempDir + "/manifest/skills/new-skill.yaml"))
    }

    func testUpsertRejectsDuplicateInFileSlugs() throws {
        var snapshot = sampleManifestSnapshot()
        snapshot.skills.append(SkillOverlay(
            slug: "second",
            createdAt: Date(),
            scope: .user,
            tags: [],
            cursor: nil,
            agents: [],
            origin: .authored
        ))
        try service.write(snapshot, toRoot: tempDir)
        let path = tempDir + "/manifest/skills/second.yaml"
        let original = try fileService.readFile(at: path)
        let duplicated = original.replacingOccurrences(of: "slug: second", with: "slug: plain")
        try fileService.writeFile(at: path, content: duplicated)

        XCTAssertThrowsError(
            try service.upsertSkillOverlay(snapshot.skills[0], toRoot: tempDir)
        ) { error in
            XCTAssertEqual(error as? ManifestError, .corruptManifestFile("skills/plain.yaml"))
        }
        XCTAssertEqual(try fileService.readFile(at: path), duplicated)
    }

    private func unrelatedManifestBytes(excludingSkill slug: String) throws -> [String: Data] {
        try manifestTreeBytes().filter { path, _ in
            path != "skills/\(slug).yaml"
        }
    }

    private func manifestTreeBytes() throws -> [String: Data] {
        let root = tempDir + "/manifest"
        var result: [String: Data] = [:]
        try collectBytes(at: root, relativePath: "", into: &result)
        return result
    }

    private func collectBytes(at root: String, relativePath: String,
                              into result: inout [String: Data]) throws {
        let directory = relativePath.isEmpty ? root : root + "/" + relativePath
        for name in try fileService.listDirectory(at: directory) {
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name
            let path = root + "/" + relative
            if fileService.directoryExists(at: path) {
                try collectBytes(at: root, relativePath: relative, into: &result)
            } else {
                result[relative] = try fileService.readData(at: path)
            }
        }
    }
}
