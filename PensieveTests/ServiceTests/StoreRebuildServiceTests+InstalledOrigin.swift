import SwiftData
import XCTest
@testable import Pensieve

extension StoreRebuildServiceTests {
    private func installedOriginBlock(slug: String) throws -> String {
        let raw = try fileService.readFile(at: tempDir + "/manifest/skills/\(slug).yaml")
        let range = try XCTUnwrap(raw.range(of: "origin:\n"))
        return String(raw[range.lowerBound...])
    }

    @MainActor
    func testInstalledOriginSurvivesRebuildAndSnapshot() throws {
        let context = try makeContext()
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
        try writeSkillFile(slug: "pdf", name: "PDF", description: "PDF tools")
        try writeManifest(skills: [
            overlay("pdf", tags: ["documents"], origin: .installed(installed), createdAt: installedDate)
        ])
        let originalOriginBlock = try installedOriginBlock(slug: "pdf")

        let result = service.rebuild(fromRoot: tempDir, context: context)
        XCTAssertEqual(result.skillsInserted, 1)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertNotNil(skill.installedOriginData)
        XCTAssertEqual(skill.installedOrigin, installed)
        XCTAssertNil(skill.importedFrom)

        try manifest.write(manifest.snapshot(from: context), toRoot: tempDir)
        XCTAssertEqual(try installedOriginBlock(slug: "pdf"), originalOriginBlock)

        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills", storeRoot: tempDir)
        let viewModel = SkillLibraryViewModel(
            skillStore: store,
            fileService: fileService, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: manifest, manifestRoot: tempDir
        )
        viewModel.updateMetadata(skill, tags: ["documents", "edited"], scope: .project, context: context)

        XCTAssertNil(viewModel.error)
        XCTAssertEqual(try installedOriginBlock(slug: "pdf"), originalOriginBlock)
        let rewritten = try XCTUnwrap(try manifest.read(fromRoot: tempDir).skills.first)
        XCTAssertEqual(rewritten.origin, .installed(installed))
        XCTAssertEqual(rewritten.tags, ["documents", "edited"])
        XCTAssertEqual(rewritten.scope, .project)
    }
}
