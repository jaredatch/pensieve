import SwiftData
import XCTest
@testable import Pensieve

extension SyncEngineTests {
    func testSyncFailsClosedOnManifestWithNonScalarKey() throws {
        let git = StubGit()
        let context = try makeContext()
        try seedDiskOnlySkill("must-not-be-admitted")
        try FileManager.default.createDirectory(
            atPath: tempDir + "/manifest",
            withIntermediateDirectories: true
        )
        let manifestPath = tempDir + "/manifest/manifest.yaml"
        let hostile = "? [x]\n: y\n"
        try hostile.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try makeEngine(git: git).sync(
            root: tempDir, message: "m", credential: nil, context: context
        )) { error in
            guard case SyncError.storeUnreadable = error else {
                return XCTFail("expected storeUnreadable, got \(error)")
            }
        }
        XCTAssertTrue(git.calls.isEmpty, "must abort before commit, pull, or push")
        XCTAssertTrue(slugs(in: context).isEmpty, "must not rebuild local SwiftData")
        XCTAssertEqual(try String(contentsOfFile: manifestPath, encoding: .utf8), hostile)
    }
}
