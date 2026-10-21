import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testFallbackRefreshesRefusedMetadataBeforePublication() async throws {
        for corrupt in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            if corrupt {
                try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "not: [yaml\n")
            } else { try h.files.deleteDirectory(at: h.root + "/manifest") }
            h.recording.failingWrites = 1
            h.library.updateMetadata(h.alpha, tags: ["a"], scope: .user, context: h.context)
            await h.saves.waitUntilIdle()
            if corrupt { XCTAssertTrue(h.saves.showsDamageAlert) } else { XCTAssertNotNil(h.library.error) }
            if !corrupt {
                h.alpha.tags = ["b"]
                try h.context.save()
                h.saves.refreshRefused(durable: nil)
                let projected = StoreIngestState.shared(for: h.context.container)
                    .projectingEdits(onto: try h.manifest.snapshot(from: h.context)).snapshot
                XCTAssertEqual(projected.skills.first { $0.slug == "alpha" }?.tags, ["b"],
                               "A nil-durable refresh must re-register the current refused projection")
            }
            h.library.updateMetadata(h.alpha, tags: ["b"], scope: .user, context: h.context)
            await h.saves.waitUntilIdle()
            if corrupt {
                h.recording.failingWrites = 0
                h.saves.requestRepair()
                await h.saves.replaceWithThisMac(context: h.context)
                await h.saves.waitUntilIdle()
            }
            XCTAssertNil(h.library.error)
            XCTAssertEqual(h.recording.writes.count, corrupt ? 2 : 1)
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["b"])
            XCTAssertEqual(h.alpha.tags, ["b"], "A refused fallback edit must use the current context before publishing")
        }
    }

    func testPartialAcknowledgementRetiresOnlyTheDurableSharedField() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.recording.failingWrites = 1
        h.library.updateMetadata(h.alpha, tags: ["local"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.saves.refused.count, 1)
        var partial = try h.manifest.read(fromRoot: h.root)
        let index = try XCTUnwrap(partial.skills.firstIndex { $0.slug == "alpha" })
        partial.skills[index].tags = ["local"]
        partial.skills[index].scope = .user
        h.saves.refreshRefused(durable: partial)
        XCTAssertEqual(h.saves.refused.count, 1, "The scope is still refused after tags become durable")
        partial.skills[index].tags = ["outside-after-ack"]
        try h.manifest.write(partial, toRoot: h.root)
        _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: h.root, context: h.context)
        XCTAssertEqual(h.alpha.tags, ["outside-after-ack"], "Shared ingestion must retire an acknowledged field")
        XCTAssertEqual(h.alpha.scope, .project, "The independently refused scope must survive ingestion")
    }

}
