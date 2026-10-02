import XCTest
@testable import Pensieve

extension ManifestServiceTests {
    func testEveryManifestReaderNamesNonScalarKeyFileAsCorrupt() throws {
        let machineID = checkedYAMLMachineID
        let snapshot = checkedYAMLSnapshot(machineID: machineID)

        for kind in ManifestFileKind.allCases {
            try service.write(snapshot, toRoot: tempDir)
            let relativePath = try manifestPath(for: kind, machineID: machineID)
            let path = tempDir + "/manifest/" + relativePath
            let valid = try fileService.readFile(at: path)
            let shadowKey = manifestShadowKey(for: kind)
            XCTAssertNoThrow(try service.read(fromRoot: tempDir), kind.rawValue)
            let benign = CheckedYAMLLoaderTests.validDocument(
                valid, shadowing: shadowKey, containing: "benign: true"
            )
            try fileService.writeFile(at: path, content: benign)
            XCTAssertNoThrow(try service.read(fromRoot: tempDir), kind.rawValue + " benign")

            for fixture in CheckedYAMLLoaderTests.nonScalarKeyFixtures {
                let yaml = CheckedYAMLLoaderTests.validDocument(
                    valid, shadowing: shadowKey, containing: fixture.yaml
                )
                let label = kind.rawValue + " " + fixture.name
                XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: yaml), label) { error in
                    XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, .nonScalarKey)
                }
                try fileService.writeFile(at: path, content: yaml)
                XCTAssertThrowsError(try service.read(fromRoot: tempDir), label) { error in
                    XCTAssertEqual(error as? ManifestError, .corruptManifestFile(relativePath))
                }
            }
        }
    }

    func testLargestSupportedManifestShapeRoundTripsThroughCheckedLoader() throws {
        let slugs = (0..<5_000).map { String(format: "skill-%04d", $0) }
        let skills = slugs.map {
            SkillOverlay(slug: $0, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                         scope: .user, tags: [], cursor: nil, agents: [], origin: .authored)
        }
        let categories = (0..<500).map { index in
            CategoryRecord(
                name: String(format: "Category %03d", index),
                projectKeys: [String(format: "marker:project-%03d", index)],
                skillSlugs: index == 0 ? slugs : []
            )
        }
        let projects = (0..<500).map { index in
            ProjectIdentityRecord(
                identityKey: String(format: "marker:project-%03d", index),
                identityKind: "marker",
                name: String(format: "Project %03d", index)
            )
        }
        let snapshot = ManifestSnapshot(
            schemaVersion: ManifestService.currentSchemaVersion,
            categories: categories,
            scenarios: [],
            projects: projects,
            skills: skills
        )

        try service.write(snapshot, toRoot: tempDir)
        let loaded = try service.read(fromRoot: tempDir)

        XCTAssertEqual(loaded.skills, skills)
        XCTAssertEqual(loaded.categories, categories)
        XCTAssertEqual(loaded.projects, projects)
    }

    func testResourceLimitDocumentsNameManifestAsCorrupt() throws {
        let machineID = checkedYAMLMachineID
        let snapshot = checkedYAMLSnapshot(machineID: machineID)

        for kind in ManifestFileKind.allCases {
            try service.write(snapshot, toRoot: tempDir)
            let relativePath = try manifestPath(for: kind, machineID: machineID)
            let path = tempDir + "/manifest/" + relativePath
            let valid = try fileService.readFile(at: path)
            let shadowKey = manifestShadowKey(for: kind)
            XCTAssertNoThrow(try service.read(fromRoot: tempDir), kind.rawValue)
            let benign = CheckedYAMLLoaderTests.validDocument(
                valid, shadowing: shadowKey, containing: "benign: true"
            )
            try fileService.writeFile(at: path, content: benign)
            XCTAssertNoThrow(try service.read(fromRoot: tempDir), kind.rawValue + " benign")

            for fixture in CheckedYAMLLoaderTests.resourceLimitFixtures {
                let yaml = CheckedYAMLLoaderTests.validDocument(
                    valid, shadowing: shadowKey, containing: fixture.yaml
                )
                let label = kind.rawValue + " " + fixture.name
                XCTAssertThrowsError(try CheckedYAMLLoader.load(yaml: yaml), label) { error in
                    XCTAssertEqual(error as? CheckedYAMLLoader.LoaderError, fixture.error)
                }
                try fileService.writeFile(at: path, content: yaml)
                let start = Date()
                XCTAssertThrowsError(try service.read(fromRoot: tempDir), label) { error in
                    XCTAssertEqual(error as? ManifestError, .corruptManifestFile(relativePath))
                }
                XCTAssertLessThan(Date().timeIntervalSince(start), 1, label)
            }
        }
    }

    func testOversizedTagsNameManifestAsCorruptQuickly() throws {
        try service.write(checkedYAMLSnapshot(machineID: checkedYAMLMachineID), toRoot: tempDir)
        let path = tempDir + "/manifest/manifest.yaml"

        for fixture in CheckedYAMLLoaderTests.oversizedTagDocuments {
            try fileService.writeFile(at: path, content: fixture.yaml)
            let start = Date()
            XCTAssertThrowsError(try service.read(fromRoot: tempDir), fixture.name) { error in
                XCTAssertEqual(error as? ManifestError, .corruptManifestFile("manifest.yaml"))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, fixture.name)
        }
    }

    private var checkedYAMLMachineID: String { "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" }

    private func checkedYAMLSnapshot(machineID: String) -> ManifestSnapshot {
        ManifestSnapshot(
            schemaVersion: ManifestService.currentSchemaVersion,
            categories: [CategoryRecord(name: "Category", projectKeys: [], skillSlugs: [])],
            scenarios: [ScenarioRecord(id: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", name: "Scenario",
                                       skillSlugs: [], agents: [])],
            projects: [],
            skills: [SkillOverlay(slug: "skill", createdAt: Date(timeIntervalSince1970: 0),
                                  scope: .user, tags: [], cursor: nil, agents: [], origin: .authored)],
            deployIntents: [DeployIntentRecord(machineID: machineID, skillSlug: "skill",
                                               platformRaw: "codex", projectKey: nil)]
        )
    }

    private func manifestShadowKey(for kind: ManifestFileKind) -> String {
        switch kind {
        case .schema:
            "schema_version"
        case .category, .scenario:
            "name"
        case .skill, .deployIntent:
            "slug"
        case .projects:
            "projects"
        }
    }

    private enum ManifestFileKind: String, CaseIterable {
        case schema
        case category
        case scenario
        case skill
        case projects
        case deployIntent
    }

    private func manifestPath(for kind: ManifestFileKind, machineID: String) throws -> String {
        switch kind {
        case .schema:
            return "manifest.yaml"
        case .category:
            let name = try XCTUnwrap(try fileService.listDirectory(at: tempDir + "/manifest/categories").first)
            return "categories/" + name
        case .scenario:
            let name = try XCTUnwrap(try fileService.listDirectory(at: tempDir + "/manifest/scenarios").first)
            return "scenarios/" + name
        case .skill:
            return "skills/skill.yaml"
        case .projects:
            return "projects.yaml"
        case .deployIntent:
            return "deploys/" + machineID + "/skill.yaml"
        }
    }
}
