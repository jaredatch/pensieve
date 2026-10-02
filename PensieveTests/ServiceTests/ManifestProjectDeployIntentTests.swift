import SwiftData
import XCTest
@testable import Pensieve

extension ManifestDeployIntentTests {
    func testProjectAndUserWideRoundTripIsFixedPoint() throws {
        let records = [
            record(platform: "codex"),
            record(platform: "cursor", projectKey: "github.com/owner/one"),
            record(platform: "future.agent", projectKey: "github.com/owner/one"),
            record(platform: "claude", projectKey: "github.com/owner/two")
        ]
        try service.write(snapshot(records), toRoot: tempDir)
        let firstBytes = try fileService.readFile(at: intentPath())

        XCTAssertEqual(canonical(try service.read(fromRoot: tempDir).deployIntents), canonical(records))
        try service.write(try service.read(fromRoot: tempDir), toRoot: tempDir)
        XCTAssertEqual(try fileService.readFile(at: intentPath()), firstBytes)
    }

    func testUserWideFileMatchesSchemaFourBytes() throws {
        let records = [record(platform: "codex"), record(platform: "future.agent")]
        try service.write(snapshot(records), toRoot: tempDir)

        XCTAssertEqual(
            try fileService.readFile(at: intentPath()),
            "slug: alpha\nplatforms:\n  - codex\n  - future.agent\n"
        )
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/manifest.yaml"), "schema_version: 5\n")
    }

    func testSchemaFourReadAndFirstWriteUpgrade() throws {
        let v4 = ManifestService(fileService: fileService, supportedSchemaVersion: 4)
        let records = [record(platform: "codex"), record(platform: "future.agent")]
        try v4.write(snapshot(records), toRoot: tempDir)

        let read = try service.read(fromRoot: tempDir)
        XCTAssertEqual(canonical(read.deployIntents), canonical(records))
        try service.write(read, toRoot: tempDir)
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/manifest/manifest.yaml"), "schema_version: 5\n")
    }

    func testSchemaFourEmptyPlatformListReadsAsNoRecordsButNullIsCorrupt() throws {
        let v4 = ManifestService(fileService: fileService, supportedSchemaVersion: 4)
        try v4.write(snapshot([]), toRoot: tempDir)
        try fileService.createDirectory(at: tempDir + "/manifest/deploys/" + Self.machineA)
        try fileService.writeFile(
            at: intentPath(),
            content: "slug: alpha\nplatforms: []\n"
        )

        XCTAssertEqual(try service.read(fromRoot: tempDir).deployIntents, [])

        try fileService.writeFile(at: intentPath(), content: "slug: alpha\nplatforms:\n")
        XCTAssertThrowsError(try service.read(fromRoot: tempDir)) { error in
            XCTAssertEqual(
                error as? ManifestError,
                .corruptManifestFile("deploys/" + Self.machineA + "/alpha.yaml")
            )
        }
    }

    func testSchemaFourReaderWriterAndRebuildRefuseSchemaFiveWithoutMutation() throws {
        let records = [record(), record(projectKey: "github.com/owner/repo")]
        try service.write(snapshot(records), toRoot: tempDir)
        let beforeTree = try manifestTree(at: tempDir)
        let v4 = ManifestService(fileService: fileService, supportedSchemaVersion: 4)
        XCTAssertThrowsError(try v4.read(fromRoot: tempDir)) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedSchema(found: 5, supported: 4))
        }
        XCTAssertThrowsError(try v4.write(snapshot([]), toRoot: tempDir))
        XCTAssertEqual(try manifestTree(at: tempDir), beforeTree)

        let context = try makeContext()
        context.insert(MachineDeployIntent(
            machineID: Self.machineB,
            skillSlug: "preserved",
            platformRaw: "codex"
        ))
        try context.save()
        let result = StoreRebuildService(fileService: fileService, manifestService: v4)
            .rebuild(fromRoot: tempDir, context: context)
        XCTAssertTrue(result.storeUnreadable)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key), [
            Self.machineB + "|preserved|codex"
        ])
    }

    func testMalformedProjectShapesFailClosed() throws {
        let bodies = [
            "slug: alpha\nplatforms:\n  - codex\nprojects: scalar\n",
            projectBody("  - key: one\n    platforms:\n      - codex\n    extra: true"),
            projectBody("  - platforms:\n      - codex"),
            projectBody("  - key: one"),
            projectBody("  - key: one\n    platforms:"),
            projectBody("  - key: one\n    platforms:\n      - codex\n  - key: one\n    platforms:\n      - cursor"),
            projectBody("  - key: one\n    platforms:\n      - bad|raw")
        ]
        for body in bodies {
            try resetManifest()
            try writeRaw(machine: Self.machineA, file: "alpha.yaml", body: body)
            assertCorrupt()
        }
    }

    func testProjectsKeyInSchemaFourFailsClosed() throws {
        let v4 = ManifestService(fileService: fileService, supportedSchemaVersion: 4)
        try v4.write(snapshot([record()]), toRoot: tempDir)
        try fileService.writeFile(
            at: intentPath(),
            content: projectBody("  - key: one\n    platforms:\n      - codex")
        )
        XCTAssertThrowsError(try v4.read(fromRoot: tempDir))
    }

    func testSchemaFourWriterRejectsProjectIntentBeforeWriting() {
        let root = tempDir + "/v4-project-rejection"
        let v4 = ManifestService(fileService: fileService, supportedSchemaVersion: 4)

        XCTAssertThrowsError(try v4.write(snapshot([
            record(projectKey: "github.com/owner/project")
        ]), toRoot: root))
        XCTAssertFalse(fileService.fileExists(at: root + "/manifest/manifest.yaml"))
    }

    func testProjectKeyAdmissionOnReadAndWrite() throws {
        let invalid = ["", String(repeating: "a", count: 513), " leading", "trailing ",
                       "line\nbreak", "nul\u{0}byte", "escape\u{1B}byte",
                       "line\u{2028}separator", "paragraph\u{2029}separator",
                       "override\u{202E}value", "joiner\u{200D}value",
                       "noncharacter\u{FFFE}value", "noncharacter\u{FFFF}value"]
        for (index, key) in invalid.enumerated() {
            XCTAssertFalse(ManifestService.isAdmittedProjectKey(key))
            let root = tempDir + "/invalid-project-key-\(index)"
            XCTAssertThrowsError(try service.write(snapshot([record(projectKey: key)]), toRoot: root))
            XCTAssertFalse(fileService.directoryExists(at: root + "/manifest"))
        }
        for scalar in ["\"\"", "\"" + String(repeating: "a", count: 513) + "\"",
                       "\" leading\"", "\"trailing \"", "\"line\\nbreak\"",
                       "\"nul\\0byte\"", "\"escape\\e byte\"",
                       "\"line\\u2028separator\"", "\"paragraph\\u2029separator\"",
                       "\"override\\u202evalue\"", "\"joiner\\u200dvalue\"",
                       "\"noncharacter\\ufffevalue\"", "\"noncharacter\\uffffvalue\""] {
            try resetManifest()
            try writeRaw(
                machine: Self.machineA,
                file: "alpha.yaml",
                body: projectBody("  - key: \(scalar)\n    platforms:\n      - codex")
            )
            assertCorrupt()
        }
    }

    func testAdmittedProjectKeyScalarsAreYAMLPrintableAndBoundariesRoundTrip() throws {
        let nonPrintable = (0...0x10_FFFF).compactMap { value -> Unicode.Scalar? in
            guard let scalar = Unicode.Scalar(value), !Self.isYAMLPrintable(scalar) else { return nil }
            return scalar
        }
        for scalar in nonPrintable {
            XCTAssertFalse(
                ManifestService.isAdmittedProjectKey("left\(scalar)right"),
                "Admitted non-printable scalar U+\(String(scalar.value, radix: 16, uppercase: true))"
            )
        }

        let boundaries = [0x20, 0x7E, 0x85, 0xA0, 0xD7FF, 0xE000, 0xFFFD, 0x1_0000, 0x10_FFFF]
        for value in boundaries {
            guard let scalar = Unicode.Scalar(value) else {
                XCTFail("Missing Unicode scalar U+\(String(value, radix: 16, uppercase: true))")
                continue
            }
            let key = "left\(scalar)right"
            guard ManifestService.isAdmittedProjectKey(key) else { continue }
            let root = tempDir + "/printable-boundary-\(value)"
            let records = [record(projectKey: key)]
            try service.write(snapshot(records), toRoot: root)
            XCTAssertEqual(canonical(try service.read(fromRoot: root).deployIntents), canonical(records))
        }
    }

    func testPermittedProjectKeysRoundTripExactly() throws {
        let keys = ["github.com/owner/repo", "a|b", "host:path", "inner space", "café/工具", "😀", "e\u{301}"]
        let records = keys.map { record(projectKey: $0) }
        try service.write(snapshot(records), toRoot: tempDir)
        XCTAssertEqual(canonical(try service.read(fromRoot: tempDir).deployIntents), canonical(records))
    }

    func testRowIdentitySeparatesScopesAndPipeKeys() throws {
        let context = try makeContext()
        let rows = [
            MachineDeployIntent(machineID: Self.machineA, skillSlug: "alpha", platformRaw: "codex"),
            MachineDeployIntent(
                machineID: Self.machineA, skillSlug: "alpha", platformRaw: "codex", projectKey: "a|b"
            ),
            MachineDeployIntent(
                machineID: Self.machineA, skillSlug: "alpha", platformRaw: "codex", projectKey: "a|c"
            )
        ]
        for row in rows { context.insert(row) }
        try context.save()
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key)).count, 3)

        context.insert(MachineDeployIntent(
            machineID: Self.machineA, skillSlug: "alpha", platformRaw: "codex", projectKey: "a|b"
        ))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 3)
    }

    func testProjectRebuildIsIdempotentAndRetractsOneRow() throws {
        let initial = [
            record(),
            record(platform: "codex", projectKey: "one"),
            record(platform: "cursor", projectKey: "one"),
            record(platform: "codex", projectKey: "two")
        ]
        try service.write(snapshot(initial), toRoot: tempDir)
        let context = try makeContext()
        let rebuild = StoreRebuildService(fileService: fileService, manifestService: service)
        let first = rebuild.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(first.deployIntentsInserted, 4)
        XCTAssertEqual(rebuild.rebuild(fromRoot: tempDir, context: context), RebuildResult())

        let remaining = initial.filter { $0.projectKey != "one" || $0.platformRaw != "cursor" }
        try service.write(snapshot(remaining), toRoot: tempDir)
        let third = rebuild.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(third.deployIntentsRemoved, 1)
        XCTAssertEqual(canonical(try service.snapshot(from: context).deployIntents), canonical(remaining))
    }

    func testRemoteProjectIntentSurvivesRebuildSnapshotAndWrite() throws {
        let records = [
            record(machine: Self.machineB, projectKey: "github.com/remote/repo"),
            record(machine: Self.machineB, platform: "future.agent", projectKey: "github.com/remote/repo")
        ]
        try service.write(snapshot(records), toRoot: tempDir)
        let context = try makeContext()
        _ = StoreRebuildService(fileService: fileService, manifestService: service)
            .rebuild(fromRoot: tempDir, context: context)
        try service.write(try service.snapshot(from: context), toRoot: tempDir)
        XCTAssertEqual(canonical(try service.read(fromRoot: tempDir).deployIntents), canonical(records))
    }

    func testSyncedComplexProjectKeySurvivesRebuildAndNextManifestWrite() throws {
        try resetManifest()
        let expected = record(platform: "codex", projectKey: "? -")
        try writeRaw(
            machine: Self.machineA,
            file: "alpha.yaml",
            body: projectBody("  - key: \"? -\"\n    platforms:\n      - codex")
        )
        let context = try makeContext()
        _ = StoreRebuildService(fileService: fileService, manifestService: service)
            .rebuild(fromRoot: tempDir, context: context)

        let rebuilt = try service.snapshot(from: context)
        XCTAssertTrue(rebuilt.deployIntents.contains(expected))
        try service.write(rebuilt, toRoot: tempDir)

        XCTAssertTrue(try service.read(fromRoot: tempDir).deployIntents.contains(expected))
    }

    func testGeneratedProjectIntentWriterSweep() throws {
        let specialKeys = [
            "/", "|", ":", "#", "'", "\"", "\\", "-leading", "?", "&", "*", "!", "%", "@", "`",
            "{", "}", "[", "]", ",", "inner space", "yes", "no", "null", "true", "~", "1e3", "0x1",
            "café", "😀", "e\u{301}", String(repeating: "a", count: 512),
            "? -", "? [x]", "[a]: b", "{a: 1}: x", "? a", "- ? b"
        ]
        try assertWriterSweepShape([record(platform: "codex")])
        for (index, key) in specialKeys.enumerated() {
            for includesUserWide in [false, true] {
                for projectCount in [1, 2] {
                    for projectPlatforms in [["cursor"], ["cursor", "future.agent"]] {
                        var records = includesUserWide ? [record(platform: "codex")] : []
                        for projectIndex in 0..<projectCount {
                            let projectKey = projectIndex == 0 ? key : "secondary-\(index)"
                            records.append(contentsOf: projectPlatforms.map {
                                record(platform: $0, projectKey: projectKey)
                            })
                        }
                        try assertWriterSweepShape(records)
                    }
                }
            }
        }
    }

    private func assertWriterSweepShape(_ records: [DeployIntentRecord]) throws {
        try service.write(snapshot(records), toRoot: tempDir)
        let bytes = try fileService.readFile(at: intentPath())
        XCTAssertEqual(canonical(try service.read(fromRoot: tempDir).deployIntents), canonical(records))
        try service.write(try service.read(fromRoot: tempDir), toRoot: tempDir)
        XCTAssertEqual(try fileService.readFile(at: intentPath()), bytes)

        for variant in [bytes.replacingOccurrences(of: "\n", with: "\r\n"), String(bytes.dropLast())] {
            try fileService.writeFile(at: intentPath(), content: variant)
            do {
                XCTAssertEqual(canonical(try service.read(fromRoot: tempDir).deployIntents), canonical(records))
            } catch {
                guard case ManifestError.corruptManifestFile = error else { throw error }
            }
        }
    }

    private func canonical(_ records: [DeployIntentRecord]) -> [String] {
        records.map {
            [$0.machineID, $0.skillSlug, $0.platformRaw, $0.projectKey ?? "<user-wide>"].joined(separator: "|")
        }.sorted()
    }

    private static func isYAMLPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x20...0x7E, 0x85, 0xA0...0xD7FF,
             0xE000...0xFFFD, 0x1_0000...0x10_FFFF:
            true
        default:
            false
        }
    }

    private func projectBody(_ projects: String) -> String {
        "slug: alpha\nplatforms:\n  - codex\nprojects:\n" + projects + "\n"
    }

    private func manifestTree(at root: String) throws -> [String: String] {
        let manifest = root + "/manifest"
        var result: [String: String] = [:]
        for top in try fileService.listDirectory(at: manifest).sorted() {
            let path = manifest + "/" + top
            if fileService.isRegularFile(at: path) {
                result[top] = try fileService.readFile(at: path)
            } else if fileService.directoryExists(at: path) {
                for child in try fileService.listDirectory(at: path).sorted() {
                    let childPath = path + "/" + child
                    if fileService.isRegularFile(at: childPath) {
                        result[top + "/" + child] = try fileService.readFile(at: childPath)
                    } else if fileService.directoryExists(at: childPath) {
                        for leaf in try fileService.listDirectory(at: childPath).sorted() {
                            result[top + "/" + child + "/" + leaf] = try fileService.readFile(
                                at: childPath + "/" + leaf
                            )
                        }
                    }
                }
            }
        }
        return result
    }
}
