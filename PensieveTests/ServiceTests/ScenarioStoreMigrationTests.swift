import SwiftData
import SQLite3
import XCTest
@testable import Pensieve

@MainActor
final class ScenarioStoreMigrationTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    func testLegacyDiskStoreKeepsRemainingRows() throws {
        let directory = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("PreScenarioRemoval.store"), to: url)
        try assertLegacyRows(at: url)
        let expected = try JSONDecoder().decode([String: [[String]]].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("PreScenarioRemoval.json")))

        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: url))
        XCTAssertEqual(try rows(in: ModelContext(container)), expected)
        XCTAssertEqual(Set(container.schema.entities.map(\.name)), Set(expected.keys))
    }

    /// Verify the frozen old-build fixture actually contains both retired entities before migration.
    private func assertLegacyRows(at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close(opened) }
        for table in ["ZSCENARIO", "ZSCENARIOASSIGNMENT"] {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil), SQLITE_OK)
            let query = try XCTUnwrap(statement)
            defer { sqlite3_finalize(query) }
            XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(query, 0), 1, table)
        }
    }

    /// Includes each persisted property, including local caches and assignment keys absent from the manifest.
    private func rows(in context: ModelContext) throws -> [String: [[String]]] {
        func row(_ values: [Any?]) -> [String] { values.map { $0.map { String(reflecting: $0) } ?? "nil" } }
        return [
            "Skill": try context.fetch(FetchDescriptor<Skill>()).map {
                row([$0.id, $0.name, $0.skillDescription, $0.tags, $0.scope.rawValue, $0.directoryName,
                     $0.cursorConfigData?.base64EncodedString(), $0.createdAt.timeIntervalSince1970,
                     $0.updatedAt.timeIntervalSince1970,
                     $0.importedFrom, $0.installedOriginData?.base64EncodedString(), $0.updateAvailable,
                     $0.lastCheckedAt?.timeIntervalSince1970,
                     $0.lastCheckedHead, $0.upstreamTree, $0.upstreamCommit, $0.upstreamCommitDate?.timeIntervalSince1970,
                     $0.checkError])
            },
            "Project": try context.fetch(FetchDescriptor<Project>()).map {
                row([$0.id, $0.name, $0.path, $0.identityKey, $0.identityKind, $0.createdAt.timeIntervalSince1970])
            },
            "Category": try context.fetch(FetchDescriptor<Pensieve.Category>()).map {
                row([$0.id, $0.name, $0.createdAt.timeIntervalSince1970, $0.projectKeys, $0.skillSlugs])
            },
            "DeployRecord": try context.fetch(FetchDescriptor<DeployRecord>()).map {
                row([$0.id, $0.skillID, $0.platform.rawValue, $0.targetPath, $0.deployedAt.timeIntervalSince1970,
                     $0.contentHash, $0.projectID])
            },
            "SkillProjectAssignment": try context.fetch(FetchDescriptor<SkillProjectAssignment>()).map {
                row([$0.id, $0.skillID, $0.projectID, $0.platform.rawValue, $0.assignedAt.timeIntervalSince1970])
            },
            "RepoUpdateCursor": try context.fetch(FetchDescriptor<RepoUpdateCursor>()).map {
                row([$0.id, $0.repo, $0.ref, $0.lastSeenHead, $0.lastCheckedAt.timeIntervalSince1970])
            },
            "MachineDeployIntent": try context.fetch(FetchDescriptor<MachineDeployIntent>()).map {
                row([$0.key, $0.machineID, $0.skillSlug, $0.platformRaw, $0.projectKey])
            },
            "IntentAssignment": try context.fetch(FetchDescriptor<IntentAssignment>()).map {
                row([$0.key, $0.skillID, $0.platformRaw, $0.projectID])
            }
        ]
    }
}
