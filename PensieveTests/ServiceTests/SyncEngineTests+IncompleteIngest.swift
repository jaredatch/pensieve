import SwiftData
import XCTest
@testable import Pensieve

extension SyncEngineTests {
    @MainActor
    func testSyncWithoutPrepareRecoversIncompleteIngestBeforeWriting() throws {
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try NativeTestWork.run { [self] in
            let fixture = try IncompleteIngestFixture(base: tempDir)
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: ModelContext(container))
            try fixture.changePeer()
            let rebuild = IncompleteIngestRebuild()
            rebuild.failWhenAddedCategoryExists = true
            let engine = fixture.engine(rebuild: rebuild)
            let remoteBefore = try fixture.remoteHead()
            XCTAssertThrowsError(try engine.sync(root: fixture.app, message: "fail", credential: nil,
                                                 context: ModelContext(container))) { error in
                XCTAssertEqual(error.localizedDescription, IncompleteIngestFixture.message)
            }
            XCTAssertEqual(try fixture.remoteHead(), remoteBefore)
            // There is no coordinator prepare hook on this caller. Its fresh context is still stale.
            rebuild.failWhenAddedCategoryExists = false
            guard case .synced = try engine.sync(root: fixture.app, message: "retry", credential: nil,
                                                 context: ModelContext(container)) else { return XCTFail("retry failed") }
            try fixture.assertRemoteCategories()
        }
    }
}
