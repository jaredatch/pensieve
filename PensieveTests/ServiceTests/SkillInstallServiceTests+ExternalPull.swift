import SwiftData
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    @MainActor
    func testInstallAdoptAndUpdateIngestExternalFastForwardBeforePublishing() async throws {
        for writer in ["install", "adopt", "update"] { try await assertInstallIngest(writer, unreadableHead: false) }
    }

    @MainActor
    func testUnreadableHeadRequiresInstallAdoptAndUpdateIngest() async throws {
        for writer in ["install", "adopt", "update"] { try await assertInstallIngest(writer, unreadableHead: true) }
    }

    @MainActor
    func testInstallAdoptAndUpdateReportTheIngestFailureCause() async throws {
        for writer in ["install", "adopt", "update"] {
            try await assertInstallIngest(writer, unreadableHead: false, refuseScan: true)
        }
    }

    private func externalSource(_ service: SkillInstallService, name: String) async throws -> SkillFetchResult {
        try await BlockingWork.run {
            let repository = try self.makeRepository(named: name)
            try self.writeSkill("skills/vendor", name: "Vendor", description: "Installed fixture", in: repository)
            try self.commit(repository)
            return try service.fetch(repo: repository, ref: nil, credential: nil)
        }
    }

    private func runInstallWriter(_ writer: String, service: SkillInstallService, source: SkillFetchResult,
                                  candidate: SkillCandidate, container: ModelContainer,
                                  manifest: WriterIngestManifest) async throws {
        try await BlockingWork.run {
            let job = ModelContext(container)
            manifest.beforeWrite = {
                XCTAssertEqual(try job.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Added", "Kept"],
                               "Install ingestion must finish before the overlay is published")
            }
            switch writer {
            case "install":
                let result = try service.install(candidate: candidate, from: source, context: job)
                XCTAssertEqual(result, .installed(slug: "vendor"))
            case "adopt":
                _ = try service.adopt(existingSlug: "item", candidate: candidate, from: source, context: job)
            default:
                try service.update(existingSlug: "item", candidate: candidate, from: source, context: job)
            }
        }
    }

    @MainActor
    private func assertInstallRefusal(_ writer: String, files: RebuildReadFileService,
                                      service: SkillInstallService, source: SkillFetchResult,
                                      container: ModelContainer,
                                      manifest: WriterIngestManifest) async throws {
            let candidate = try XCTUnwrap(source.candidates.first)
            files.refuseSkillListing = true
            do {
                try await runInstallWriter(writer, service: service, source: source, candidate: candidate,
                                           container: container, manifest: manifest)
                XCTFail("The writer must refuse an unreadable skill directory")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Rebuilding the local store failed:"), writer)
                XCTAssertTrue(error.localizedDescription.contains("list"),
                              "Preserve the rebuild's directory-listing cause: \(error)")
                XCTAssertTrue(error.localizedDescription.contains("Couldn't list the skills directory"), writer)
            }
    }

    @MainActor
    private func prepareAdoptedItem(_ f: IncompleteIngestFixture, service: SkillInstallService,
                                    source: SkillFetchResult, candidate: SkillCandidate, context: ModelContext) async throws {
        let container = context.container
        try await BlockingWork.run {
            _ = try service.adopt(existingSlug: "item", candidate: candidate, from: source, context: ModelContext(container))
            _ = try f.git.stageAllAndCommit(at: f.app, message: "adopt before pull")
            try f.git.push(at: f.app, credential: nil)
            _ = try f.git.fastForwardOnly(at: f.peer, credential: nil)
        }
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: context)
    }

    @MainActor
    private func assertInstallIngest(_ writer: String, unreadableHead: Bool, refuseScan: Bool = false) async throws {
        let f = try await BlockingWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/outside-\(writer)-\(unreadableHead)")
        }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: f.app, context: context)
        let manifest = WriterIngestManifest()
        let files = RebuildReadFileService()
        let service = SkillInstallService(gitService: f.git, credentialStore: InMemoryCredentialStore(),
            fileService: files, scratchRoot: f.base + "/scratch", storeRoot: f.app,
            manifestService: manifest, lockPath: f.base + "/sync.lock",
            remoteValidator: fixtureRemoteValidator)
        let source = try await externalSource(service, name: "upstream-\(writer)-\(unreadableHead)")
        let candidate = try XCTUnwrap(source.candidates.first)
        if writer == "update" {
            try await prepareAdoptedItem(f, service: service, source: source, candidate: candidate, context: context)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Deleted", "Kept"])
        try await BlockingWork.run {
            try f.changePeer()
            guard case .fastForwarded = try f.git.fastForwardOnly(at: f.app, credential: nil) else {
                return XCTFail("The outside process must move HEAD")
            }
        }
        XCTAssertFalse(StoreIngestState.shared(for: container).needsRebuild)
        let headPath = f.app + "/.git/HEAD", head = try f.files.readFile(at: f.app + "/.git/HEAD")
        if unreadableHead {
            try f.files.writeFile(at: headPath, content: "unreadable head\n")
            XCTAssertNil(GitHeadStamp().read(root: f.app))
        }
        defer { if unreadableHead { try? f.files.writeFile(at: headPath, content: head) } }
        if refuseScan {
            try await assertInstallRefusal(writer, files: files, service: service, source: source,
                                           container: container, manifest: manifest)
            return
        }
        try await runInstallWriter(writer, service: service, source: source, candidate: candidate,
                                   container: container, manifest: manifest)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Added", "Kept"],
                       "The window must see the category by \(writer)'s completion")
        let slug = writer == "install" ? "vendor" : "item"
        XCTAssertNotNil(try context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == slug }?.installedOrigin)
        XCTAssertEqual(try f.manifest.read(fromRoot: f.app).categories.map(\.name).sorted(), ["Added", "Kept"])
        if unreadableHead { try f.files.writeFile(at: headPath, content: head) }
        try await assertWriterSync(f, container: container)
    }
    private func assertWriterSync(_ f: IncompleteIngestFixture, container: ModelContainer) async throws {
        try await BlockingWork.run {
            guard case .synced = try f.engine(rebuild: StoreRebuildService()).sync(root: f.app,
                message: "after writer", credential: nil, context: ModelContext(container)) else {
                return XCTFail("Next sync must succeed")
            }
            try f.assertRemoteCategories()
        }
    }

}
