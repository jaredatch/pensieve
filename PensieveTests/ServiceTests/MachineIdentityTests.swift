import Foundation
import XCTest
@testable import Pensieve

final class MachineIdentityTests: XCTestCase {
    private var tempDir = ""
    private let fileService = FileService()

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.url
            .appendingPathComponent("MachineIdentityTests-\(UUID().uuidString)").path
        try fileService.createDirectory(at: tempDir)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? fileService.deleteDirectory(at: tempDir) }
    }

    func testIdentityStableAcrossReads() throws {
        let identity = MachineIdentity(fileService: fileService, appSupportDir: tempDir)
        let first = try identity.identifier()
        XCTAssertEqual(try identity.identifier(), first)
        XCTAssertEqual(UUID(uuidString: first)?.uuidString, first)
    }

    func testNonCanonicalRewrittenPreservingUUID() throws {
        let expected = "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002"
        try fileService.writeFile(at: tempDir + "/machine-id", content: expected.lowercased())
        let identity = MachineIdentity(fileService: fileService, appSupportDir: tempDir)
        let actual = try identity.identifier()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/machine-id"), expected + "\n")
        try fileService.writeFile(at: tempDir + "/machine-id", content: "  " + expected + "  \n")
        XCTAssertEqual(try identity.identifier(), expected)
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/machine-id"), expected + "\n")
    }

    func testUnparseableRegenerates() throws {
        var warnings: [String] = []
        try fileService.writeFile(at: tempDir + "/machine-id", content: "not-a-uuid")
        let actual = try MachineIdentity(fileService: fileService, appSupportDir: tempDir,
                                         warn: { warnings.append($0) }).identifier()
        XCTAssertEqual(UUID(uuidString: actual)?.uuidString, actual)
        XCTAssertFalse(warnings.isEmpty)
    }

    func testSymlinkedIdentityFileRejected() throws {
        let foreign = "11111111-1111-4111-8111-111111111111"
        try fileService.writeFile(at: tempDir + "/foreign", content: foreign)
        try fileService.createSymlink(at: tempDir + "/machine-id", pointingTo: tempDir + "/foreign")
        let actual = try MachineIdentity(fileService: fileService, appSupportDir: tempDir,
                                         makeUUID: { UUID(uuidString: "22222222-2222-4222-8222-222222222222")! })
            .identifier()
        XCTAssertEqual(actual, "22222222-2222-4222-8222-222222222222")
        XCTAssertFalse(fileService.isSymlink(at: tempDir + "/machine-id"))
        XCTAssertEqual(try fileService.readFile(at: tempDir + "/foreign"), foreign)
    }

    func testForeignNonCanonicalFilenameSkipped() throws {
        let canonical = "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002"
        try writeStateFile(named: canonical.lowercased() + ".yaml", machineID: canonical)
        XCTAssertTrue(service().readAll(fromRoot: tempDir).isEmpty)
    }

    func testTraversalStateFilenameSkipped() throws {
        let canonical = "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002"
        let escaped = "11111111-1111-4111-8111-111111111111"
        try writeStateFile(named: canonical + ".yaml", machineID: canonical)
        try fileService.writeFile(at: tempDir + "/" + escaped + ".yaml",
                                  content: stateYAML(machineID: escaped))
        let listing = InjectedListingFileService(wrapped: fileService, extra: ["../" + escaped + ".yaml"])
        XCTAssertEqual(service(fileService: listing).readAll(fromRoot: tempDir).map(\.machineID), [canonical])
    }

    func testCaseVariantDuplicateFirstCanonicalWins() throws {
        let canonical = "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002"
        var warnings: [String] = []
        try writeStateFile(named: canonical + ".yaml", machineID: canonical)
        let listing = InjectedListingFileService(wrapped: fileService, extra: [canonical.lowercased() + ".yaml"])
        let states = service(fileService: listing, warn: { warnings.append($0) }).readAll(fromRoot: tempDir)
        XCTAssertEqual(states.map(\.machineID), [canonical])
        XCTAssertFalse(warnings.isEmpty)
    }

    private func service(
        fileService: FileServiceProtocol? = nil, warn: @escaping (String) -> Void = { _ in }
    ) -> MachineStateService {
        MachineStateService(fileService: fileService ?? self.fileService, agentDetection: EmptyMachineDetection(),
                            defaults: UserDefaults(), hostName: { "Test Mac" }, appVersion: { "test" }, warn: warn)
    }

    private func writeStateFile(named name: String, machineID: String) throws {
        let directory = tempDir + "/machines"
        try fileService.createDirectory(at: directory)
        try fileService.writeFile(at: directory + "/" + name, content: stateYAML(machineID: machineID))
    }
}

private struct InjectedListingFileService: FileServiceProtocol {
    let wrapped: FileService
    let extra: [String]
    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func writeFile(at path: String, content: String) throws { try wrapped.writeFile(at: path, content: content) }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) + extra }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}

func stateYAML(machineID: String, schema: Int = 1) -> String {
    """
    schema_version: \(schema)
    machine_id: \(machineID)
    name: Test Mac
    app_version: test
    published_at: 2026-08-20T14:05:11Z
    agents: []
    projects: []
    user_deploys: []
    project_deploys: []
    """
}
