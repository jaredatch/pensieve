import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ManifestProjectsRetiredTests: XCTestCase {
    private var tempRoot = ""
    private let fileService = FileService()

    override func setUpWithError() throws {
        tempRoot = TestTemporaryDirectory.path + "PensieveProjectsRetired-" + UUID().uuidString
        try fileService.createDirectory(at: tempRoot)
    }

    override func tearDownWithError() throws {
        if !tempRoot.isEmpty { try fileService.deleteDirectory(at: tempRoot) }
    }

    func testSnapshotCarriesNoProjectRecordsAndWritesTheConstantFile() throws {
        let context = try makeContext()
        context.insert(registeredProject())
        try context.save()
        let service = ManifestService()

        XCTAssertTrue(try service.snapshot(from: context).projects.isEmpty)
        try service.write(try service.snapshot(from: context), toRoot: tempRoot)
        XCTAssertEqual(try fileService.readFile(at: tempRoot + "/manifest/projects.yaml"), "projects:\n")
        XCTAssertTrue(try service.read(fromRoot: tempRoot).projects.isEmpty)
    }

    func testProjectIdentityStillReachesTheMachineState() throws {
        let context = try makeContext()
        context.insert(registeredProject())
        try context.save()
        let service = MachineStateService(
            fileService: fileService,
            agentDetection: EmptyMachineDetection(),
            defaults: try isolatedDefaults(),
            deployState: { DeployState(schemaVersion: 1, records: []) },
            homeDirectory: TestPaths.homeDirectory,
            hostName: { "Fixture Mac" },
            appVersion: { "0.0.0" },
            warn: { _ in }
        )

        let state = try service.compose(
            machineID: UUID().uuidString,
            context: context,
            publishedAt: Date()
        )

        XCTAssertEqual(state.projects.count, 1)
        let project = try XCTUnwrap(state.projects.first)
        XCTAssertEqual(project.identityKey, "github.com/jaredatch/lab.example.com")
        XCTAssertEqual(project.kind, "remote")
        XCTAssertEqual(project.name, "test")
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    private func registeredProject() -> Project {
        let project = Project(name: "test", path: tempRoot + "/lab")
        project.identityKey = "github.com/jaredatch/lab.example.com"
        project.identityKind = "remote"
        return project
    }
}
