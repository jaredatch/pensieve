import SwiftData
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    @MainActor
    func testInstallAdoptAndUpdatePreserveDamagedManifestAtUnchangedHead() throws {
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run(container: container) { context in
            let repository = try self.makeVendorFixture()
            let source = try self.service.fetch(repo: repository, ref: nil, credential: nil)
            let candidate = try XCTUnwrap(source.candidates.first)
            for writer in ["install", "adopt", "update"] {
                let root = self.tempDir + "/damaged-" + writer
                let installer = self.makeInstallService(root: root)
                let manifest = ManifestService()
                if writer != "install" {
                    _ = try installer.install(candidate: candidate, from: source, context: context)
                    if writer == "adopt" {
                        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
                        row.installedOrigin = nil
                        try context.save()
                        try manifest.write(manifest.snapshot(from: context), toRoot: root)
                    }
                } else {
                    try manifest.write(manifest.snapshot(from: context), toRoot: root)
                }
                try self.gitService.initRepository(at: root)
                _ = try self.gitService.stageAllAndCommit(at: root, message: "ingested library")
                _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: root, context: context)
                let head = GitHeadStamp().read(root: root)
                XCTAssertNotNil(head)
                try self.fileService.writeFile(at: root + "/manifest/manifest.yaml", content: "damaged")
                let bytes = try ManifestSaveFixture.manifestBytes(root: root, files: self.fileService)
                XCTAssertFalse(StoreIngestState.shared(for: container).needsRebuild)
                switch writer {
                case "install":
                    XCTAssertThrowsError(try installer.install(candidate: candidate, from: source, context: context))
                case "adopt":
                    XCTAssertThrowsError(try installer.adopt(existingSlug: "vendor", candidate: candidate,
                        from: source, context: context))
                default:
                    XCTAssertThrowsError(try installer.update(existingSlug: "vendor", candidate: candidate,
                        from: source, context: context))
                }
                XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: root, files: self.fileService), bytes, writer)
                XCTAssertEqual(GitHeadStamp().read(root: root), head, writer)
                for row in try context.fetch(FetchDescriptor<Skill>()) { context.delete(row) }
                try context.save()
            }
        }
    }
}
