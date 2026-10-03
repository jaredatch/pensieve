import XCTest
@testable import Pensieve

final class ManifestScenarioTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var service: ManifestService!

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveManifestScenarios-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        service = ManifestService(fileService: fileService)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testExistingScenarioBytesSurviveSnapshotChanges() throws {
        let backend = LegacyScenarioDefinition(
            id: "D23BF2CE-86FD-4F89-951D-F16E446F91F2",
            name: "Backend",
            skillSlugs: ["sql", "api"],
            agents: ["cursor", "claudeCode"]
        )
        let frontend = LegacyScenarioDefinition(
            id: "A96A4BD5-60FA-4904-AD9A-9452D87501D8",
            name: "Frontend",
            skillSlugs: ["react", "vite"],
            agents: ["codex", "cursor"]
        )
        try seedLegacy([frontend, backend])
        let before = try recursiveFiles(under: tempDir)
        try service.write(snapshot(), toRoot: tempDir)

        XCTAssertNoThrow(try service.read(fromRoot: tempDir))
        XCTAssertEqual(try recursiveFiles(under: tempDir), before)
    }

    func testHostileScenarioNamesConfined() throws {
        let records = [
            LegacyScenarioDefinition(id: "1E3AB3B9-53EF-4051-9215-201177354373", name: "../evil",
                           skillSlugs: ["one"], agents: ["codex"]),
            LegacyScenarioDefinition(id: "7CEEEAE8-75B8-4B0C-AC97-79453FE340A7", name: "a/b",
                           skillSlugs: ["two"], agents: ["cursor"]),
            LegacyScenarioDefinition(id: "8573D923-EC84-4325-8CC6-C925A22B14B1", name: "",
                           skillSlugs: [], agents: []),
            LegacyScenarioDefinition(id: "246805E8-224C-4D5E-874D-1B35BDA9BA6E", name: "日本語",
                           skillSlugs: ["unicode"], agents: ["openClaw"])
        ]

        try seedLegacy(records)
        try service.write(snapshot(), toRoot: tempDir)

        let scenariosDir = tempDir + "/manifest/scenarios"
        let files = try fileService.listDirectory(at: scenariosDir).filter { $0.hasSuffix(".yaml") }
        XCTAssertEqual(files.count, records.count)
        for file in files {
            XCTAssertFalse(file.contains("/"), file)
            XCTAssertFalse(file.contains(".."), file)
            XCTAssertTrue(file.hasSuffix(".yaml"), file)
            XCTAssertTrue(fileService.fileExists(at: scenariosDir + "/" + file), file)
        }
        XCTAssertTrue(files.contains { $0.hasPrefix("scn-") }, "empty/unicode names use the scn fallback")
        XCTAssertNoThrow(try service.read(fromRoot: tempDir))
    }

    func testNonSequenceLegacyFieldsAreIgnoredAndCarried() throws {
        let record = LegacyScenarioDefinition(id: "8787F07B-40FA-46FD-A9C2-D892D07D4661", name: "Bad Lists",
                                    skillSlugs: ["swift"], agents: ["cursor"])
        try seedLegacy([record])
        try service.write(snapshot(), toRoot: tempDir)
        let path = try scenarioPath(named: "Bad Lists")

        var raw = try fileService.readFile(at: path)
        raw = raw.replacingOccurrences(of: "skill_slugs:\n  - swift", with: "skill_slugs: swift")
        try fileService.writeFile(at: path, content: raw)
        try assertIgnoredScenarioReadAndCarry()

        try seedLegacy([record])
        try service.write(snapshot(), toRoot: tempDir)
        raw = try fileService.readFile(at: path)
        raw = raw.replacingOccurrences(of: "agents:\n  - cursor", with: "agents: cursor")
        try fileService.writeFile(at: path, content: raw)
        try assertIgnoredScenarioReadAndCarry()
    }

    func testMissingOrInvalidLegacyIDsAreIgnoredAndCarried() throws {
        try writeScenarioFile(name: "missing.yaml", content: """
        name: "Missing"
        skill_slugs:
        agents:

        """)
        try assertIgnoredScenarioReadAndCarry()

        try service.write(snapshot(), toRoot: tempDir)
        try writeScenarioFile(name: "invalid.yaml", content: """
        id: "not-a-uuid"
        name: "Invalid"
        skill_slugs:
        agents:

        """)
        try assertIgnoredScenarioReadAndCarry()
    }

    func testUnparseableScenarioFileIsIgnoredAndCarried() throws {
        try service.write(snapshot(), toRoot: tempDir)
        try fileService.writeFile(at: tempDir + "/manifest/scenarios/broken.yaml", content: ":\n  - [\n")

        try assertIgnoredScenarioReadAndCarry()
    }

    func testNewerSchemaManifestRefused() throws {
        try fileService.createDirectory(at: tempDir + "/manifest")
        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: 6\n")

        XCTAssertThrowsError(try service.read(fromRoot: tempDir)) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedSchema(found: 6, supported: 5))
        }
    }

    func testWriteRefusesNewerSchemaTree() throws {
        try fileService.createDirectory(at: tempDir + "/manifest/scenarios")
        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: 6\n")
        try fileService.writeFile(at: tempDir + "/manifest/scenarios/keep.yaml", content: "keep: bytes\n")
        let before = try recursiveFiles(under: tempDir)

        XCTAssertThrowsError(try service.write(snapshot(), toRoot: tempDir)) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedSchema(found: 6, supported: 5))
        }
        XCTAssertEqual(try recursiveFiles(under: tempDir), before)

        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: nope\n")
        try service.write(snapshot(), toRoot: tempDir)
        XCTAssertNoThrow(try service.read(fromRoot: tempDir))
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/scenarios/keep.yaml"), "keep: bytes\n")
    }

    func testDuplicateLegacyIDsKeepBothFiles() throws {
        try service.write(snapshot(), toRoot: tempDir)
        let upperID = "D52AB43B-57E4-496C-AE4D-B14A2D574F4E"
        let lowerID = upperID.lowercased()
        try writeScenarioFile(name: "a-first.yaml", content: """
        id: "\(lowerID)"
        name: "First"
        skill_slugs:
          - first
        agents:
          - codex

        """)
        try writeScenarioFile(name: "z-last.yaml", content: """
        id: "\(upperID)"
        name: "Last"
        skill_slugs:
          - last
        agents:
          - cursor

        """)

        XCTAssertNoThrow(try service.read(fromRoot: tempDir))
        try service.write(snapshot(), toRoot: tempDir)
        XCTAssertEqual(Set(try fileService.listDirectory(at: tempDir + "/manifest/scenarios")),
                       ["a-first.yaml", "z-last.yaml"])
    }

    func testSameNamedLegacyScenariosKeepDistinctFiles() throws {
        // Distinct legacy files stay distinct even when their names match.
        let idA = "0AAAAAAA-1111-4222-8333-444444444444"
        let idB = "0BBBBBBB-1111-4222-8333-444444444444"
        try seedLegacy([
            LegacyScenarioDefinition(id: idB, name: "Same", skillSlugs: ["b"], agents: ["cursor"]),
            LegacyScenarioDefinition(id: idA, name: "Same", skillSlugs: ["a"], agents: ["codex"])
        ])
        let before = try recursiveFiles(under: tempDir)
        try service.write(snapshot(), toRoot: tempDir)
        XCTAssertNoThrow(try service.read(fromRoot: tempDir))
        XCTAssertEqual(try recursiveFiles(under: tempDir), before)
    }

    func testV1TreeWithoutScenariosRemainsReadable() throws {
        try fileService.createDirectory(at: tempDir + "/manifest/categories")
        try fileService.writeFile(at: tempDir + "/manifest/manifest.yaml", content: "schema_version: 1\n")

        let read = try service.read(fromRoot: tempDir)

        XCTAssertEqual(read.schemaVersion, 1)
        XCTAssertTrue(read.skills.isEmpty)
    }

    func testWrittenTreeDeclaresSchemaVersion5() throws {
        try service.write(snapshot(), toRoot: tempDir)

        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/manifest.yaml"), "schema_version: 5\n")
    }

    private func snapshot() -> ManifestSnapshot {
        ManifestSnapshot(
            schemaVersion: ManifestService.currentSchemaVersion,
            categories: [],
            projects: [],
            skills: []
        )
    }

    private func scenarioPath(named name: String) throws -> String {
        let scenariosDir = tempDir + "/manifest/scenarios"
        let file = try XCTUnwrap(try fileService.listDirectory(at: scenariosDir).first {
            try fileService.readFile(at: scenariosDir + "/" + $0).contains("name: \(SkillSerializer.quotedScalar(name))")
        })
        return scenariosDir + "/" + file
    }

    private func writeScenarioFile(name: String, content: String) throws {
        try fileService.writeFile(at: tempDir + "/manifest/scenarios/" + name, content: content)
    }

    private func assertIgnoredScenarioReadAndCarry(file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try recursiveFiles(under: tempDir)
        XCTAssertNoThrow(try service.read(fromRoot: tempDir), file: file, line: line)
        try service.write(snapshot(), toRoot: tempDir)
        let after = try recursiveFiles(under: tempDir)
        for (path, bytes) in before where path.hasPrefix("manifest/scenarios/") {
            XCTAssertEqual(after[path], bytes, file: file, line: line)
        }
    }

    private func seedLegacy(_ records: [LegacyScenarioDefinition]) throws {
        try service.write(snapshot(), toRoot: tempDir)
        for record in records {
            try writeScenarioFile(name: LegacyScenarioDefinition.fileName(name: record.name, id: record.id),
                                  content: LegacyScenarioDefinition.serialize(record))
        }
    }

    private func recursiveFiles(under root: String) throws -> [String: String] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var files: [String: String] = [:]
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let relative = String(url.path.dropFirst(rootURL.path.count + 1))
            files[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }
}
