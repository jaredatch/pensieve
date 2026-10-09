import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ManifestLockRegressionTests: XCTestCase {
    func testCategoryMutationDoesNotPublishThroughHeldSyncLock() async throws {
        let root = TestTemporaryDirectory.path + "manifest-lock-regression-" + UUID().uuidString
        let files = FileService()
        defer { try? files.deleteDirectory(at: root) }
        let context = ModelContext(try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let category = Pensieve.Category(name: "Before")
        context.insert(category)
        try context.save()
        let manifest = ManifestService()
        try manifest.write(try manifest.snapshot(from: context), toRoot: root)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: root + "/sync.lock"))
        defer { lock.release() }
        CategoryStore(manifestService: manifest, manifestRoot: root).rename(category, to: "After", context: context)
        XCTAssertEqual(category.name, "After")
        // Yielding main work must neither block on the lock nor let a manifest swap pass it.
        var mainWorkRan = false
        let turn = Task { @MainActor in mainWorkRan = true }
        await turn.value
        XCTAssertTrue(mainWorkRan)
        XCTAssertEqual(try manifest.read(fromRoot: root).categories.map(\.name), ["Before"])
        lock.release()
        await TestWait.until(failureMessage: "The waiting category edit never saved") {
            (try? manifest.read(fromRoot: root).categories.map(\.name)) == ["After"]
        }
    }
}
