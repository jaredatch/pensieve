import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameTakenTests: XCTestCase {
    func testPeerArrivalReplacementAndUnreadableCreationAreRefusedWithoutWriting() async throws {
        for scenario in ["arrived", "replaced", "missing date", "invalid date"] {
            let h = try SkillRenameTakeoverFixture(record: scenario != "arrived", leftovers: scenario != "arrived")
            defer { h.cleanup() }
            let unknown = scenario == "missing date" || scenario == "invalid date"
            if unknown {
                let path = h.root + "/manifest/skills/zulu.yaml"
                let text = try h.files.readFile(at: path)
                let rewritten = text.components(separatedBy: "\n").filter { !$0.hasPrefix("created_at:") }
                    .joined(separator: "\n") + (scenario == "invalid date" ? "\ncreated_at: unreadable\n" : "")
                try h.files.writeFile(at: path, content: rewritten)
            }
            XCTAssertTrue(h.rename(), h.library.error ?? "")
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { held.release() }
            if !unknown {
                var disk = try h.manifest.read(fromRoot: h.root)
                var peer = h.leftover; peer.createdAt = Date(timeIntervalSince1970: 1_650_000_000)
                disk.skills.removeAll { $0.slug == "zulu" }; disk.skills.append(peer)
                try h.manifest.write(disk, toRoot: h.root)
            }
            let before = try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files)
            held.release()
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.library.error, h.takenMessage(), scenario)
            XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files), before, scenario)
            if unknown {
                let window = try h.manifest.snapshot(from: h.context)
                XCTAssertEqual(window.categories.first { $0.name == "Gone" }?.skillSlugs, ["zulu"])
                XCTAssertEqual(window.deployIntents.filter { $0.projectKey == "github.com/owner/gone" }.count, 2)
            }
            XCTAssertEqual(h.saves.pendingCount, 0)
        }
    }
}
