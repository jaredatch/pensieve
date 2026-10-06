import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ManifestDeployIntentTests: XCTestCase {
    static let machineA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    static let machineB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

    var tempDir: String!
    var service: ManifestService!
    let fileService = FileService()

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveManifestIntent-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        service = ManifestService(fileService: fileService)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testIntentRoundTripSnapshotRebuild() throws {
        let source = try makeContext()
        source.insert(MachineDeployIntent(machineID: Self.machineA, skillSlug: "alpha", platformRaw: "codex"))
        source.insert(MachineDeployIntent(machineID: Self.machineA, skillSlug: "alpha", platformRaw: "future.agent"))
        try source.save()
        try service.write(try service.snapshot(from: source), toRoot: tempDir)

        let destination = try makeContext()
        let result = StoreRebuildService(fileService: fileService, manifestService: service)
            .rebuild(fromRoot: tempDir, context: destination)
        let rows = try destination.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(result.deployIntentsInserted, 2)
        XCTAssertEqual(Set(rows.map(\.key)), [
            Self.machineA + "|alpha|codex",
            Self.machineA + "|alpha|future.agent"
        ])
    }

    func testRetractionDeletesRows() throws {
        try service.write(snapshot([record()]), toRoot: tempDir)
        let context = try makeContext()
        let rebuild = StoreRebuildService(fileService: fileService, manifestService: service)
        _ = rebuild.rebuild(fromRoot: tempDir, context: context)
        try service.write(snapshot([]), toRoot: tempDir)
        let result = rebuild.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.deployIntentsRemoved, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    func testV4ReaderRefusesV5Tree() throws {
        try service.write(snapshot([record()]), toRoot: tempDir)
        let v4 = ManifestService(fileService: fileService, supportedSchemaVersion: 4)
        XCTAssertThrowsError(try v4.read(fromRoot: tempDir)) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedSchema(found: 5, supported: 4))
        }
    }

    func testWriteGuardRefusesOlderOverwrite() throws {
        try service.write(snapshot([record()]), toRoot: tempDir)
        let before = try fileService.readFile(at: intentPath())
        let v4 = ManifestService(fileService: fileService, supportedSchemaVersion: 4)
        XCTAssertThrowsError(try v4.write(snapshot([]), toRoot: tempDir))
        XCTAssertEqual(try fileService.readFile(at: intentPath()), before)
    }

    func testEntryParserFailClosed() throws {
        for body in ["- alpha\n", "slug: alpha\n", "slug: 7\nplatforms:\n  - codex\n",
                     "slug: alpha\nplatforms: codex\n", "slug: alpha\nplatforms:\n  - 7\n",
                     "slug: alpha\nplatforms:\n  - codex\nextra: true\n"] {
            try writeRaw(machine: Self.machineA, file: "alpha.yaml", body: body)
            assertCorrupt()
        }
        try resetManifest()
        try fileService.deleteDirectory(at: tempDir + "/manifest/deploys")
        try fileService.writeFile(at: tempDir + "/manifest/deploys", content: "not a directory\n")
        assertCorrupt()
        try resetManifest()
        let outside = tempDir + "/outside-intents"
        try fileService.createDirectory(at: outside)
        try fileService.writeFile(at: outside + "/alpha.yaml", content: validBody())
        try fileService.createSymlink(
            at: tempDir + "/manifest/deploys/" + Self.machineA,
            pointingTo: outside
        )
        assertCorrupt()
    }

    func testNonCanonicalMachineDirFailsClosed() throws {
        try writeRaw(machine: Self.machineA.lowercased(), file: "alpha.yaml", body: validBody())
        assertCorrupt()
    }

    func testParserCharsetViolationFailsClosed() throws {
        try writeRaw(machine: Self.machineA, file: "alpha.yaml", body: "slug: alpha\nplatforms:\n  - bad|raw\n")
        assertCorrupt()
        try resetManifest()
        try writeRaw(machine: Self.machineA, file: "bad slug.yaml", body: "slug: bad slug\nplatforms:\n  - codex\n")
        assertCorrupt()
    }

    func testParserTraversalSlugFailsClosed() throws {
        for slug in [".hidden", ".."] {
            try resetManifest()
            try writeRaw(machine: Self.machineA, file: slug + ".yaml",
                         body: "slug: \(slug)\nplatforms:\n  - codex\n")
            assertCorrupt()
        }
    }

    func testParserCaseFoldedDuplicateFailsClosed() throws {
        try writeRaw(machine: Self.machineA, file: "Alpha.yaml", body: "slug: Alpha\nplatforms:\n  - codex\n")
        try writeRaw(machine: Self.machineA, file: "alpha.yaml", body: validBody())
        assertCorrupt()
    }

    func testParserFilenameStemMismatchFailsClosed() throws {
        try writeRaw(machine: Self.machineA, file: "other.yaml", body: validBody())
        assertCorrupt()
    }

    func testUnknownPlatformRawRoundTrips() throws {
        let unknown = "agent.future-2"
        try service.write(snapshot([record(platform: unknown)]), toRoot: tempDir)
        XCTAssertEqual(try service.read(fromRoot: tempDir).deployIntents.map(\.platformRaw), [unknown])
    }

    func testKeyCollisionImpossibleForAdmittedComponents() {
        let values = ["alpha", "alpha.beta", "alpha_beta", "alpha-beta"]
        XCTAssertTrue(values.allSatisfy(ManifestService.isAdmittedIntentComponent))
        let keys = Set(values.map { Self.machineA + "|" + $0 + "|codex" })
        XCTAssertEqual(keys.count, values.count)
        XCTAssertFalse(ManifestService.isAdmittedIntentComponent("alpha|beta"))
    }

    func makeContext() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    func snapshot(_ records: [DeployIntentRecord]) -> ManifestSnapshot {
        ManifestSnapshot(schemaVersion: 5, categories: [], projects: [], skills: [],
                         deployIntents: records)
    }

    func record(machine: String = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                slug: String = "alpha", platform: String = "codex", projectKey: String? = nil)
        -> DeployIntentRecord {
        DeployIntentRecord(
            machineID: machine,
            skillSlug: slug,
            platformRaw: platform,
            projectKey: projectKey
        )
    }

    func intentPath(machine: String = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                    slug: String = "alpha") -> String {
        tempDir + "/manifest/deploys/" + machine + "/" + slug + ".yaml"
    }

    func validBody(slug: String = "alpha", platforms: [String] = ["codex"]) -> String {
        ManifestService.serializeDeployIntent(slug: slug, platforms: platforms)
    }

    func resetManifest() throws { try service.write(snapshot([]), toRoot: tempDir) }

    func writeRaw(machine: String, file: String, body: String) throws {
        if !fileService.fileExists(at: tempDir + "/manifest/manifest.yaml") { try resetManifest() }
        try fileService.createDirectory(at: tempDir + "/manifest/deploys/" + machine)
        try fileService.writeFile(at: tempDir + "/manifest/deploys/" + machine + "/" + file, content: body)
    }

    func assertCorrupt(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try service.read(fromRoot: tempDir), file: file, line: line) { error in
            guard case ManifestError.corruptManifestFile = error else {
                return XCTFail("expected corrupt manifest, got \(error)", file: file, line: line)
            }
        }
    }
}
