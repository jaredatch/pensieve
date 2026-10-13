import CoreData
import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func checkFailedCategoryFetch() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let context = h.context, container = context.container
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        h.categories.rename(h.local, to: "Drafts", context: context)
        await h.assertWaitingBehindHeldLock(pending: 1, before: before)
        let fault = try CategoryFetchFault()
        let result = StoreRebuildService().rebuild(fromRoot: h.root, context: ModelContext(container))
        fault.stop()
        XCTAssertEqual(fault.refusedReads, 1, "Exercise the native category fetch failure")
        XCTAssertNil(result.categoryRead, "A failed fetch has no read receipt")
        XCTAssertEqual(result.categoriesInserted, 0, "A failed fetch must not insert duplicate categories")
        XCTAssertEqual(result.categoriesUpdated, 0)
        XCTAssertEqual(result.categoriesRemoved, 0)
        XCTAssertFalse(result.saveFailed, "The fetch refusal leaves no category mutations to save")
        XCTAssertTrue(result.warnings.contains { $0.contains("categor") }, "Report the failed category read")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Drafts", "ZDelete"])
        h.recording.failingWrites = 1
        lock.release()
        await h.saves.waitUntilIdle()
        for window in [context, ModelContext(container)] {
            XCTAssertEqual(try window.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Local", "ZDelete"])
        }
        XCTAssertTrue(try XCTUnwrap(h.saves.categoryNotice).message.contains("so it was undone."),
                      "A failed category fetch must not supersede the pending inverse")
        XCTAssertEqual(try h.manifestBytes(), before)
    }
}

/// Refuse one native Core Data category query during the synchronous rebuild. All other requests,
/// including its save and the queue's later undo, use the original implementation. Each test host
/// runs one case at a time; stop restores the method before this case yields to the queue.
private final class CategoryFetchFault {
    private let method: Method
    private let original: IMP
    private var replacement: IMP?
    private(set) var refusedReads = 0

    init() throws {
        let selector = NSSelectorFromString("executeFetchRequest:error:")
        method = try XCTUnwrap(class_getInstanceMethod(NSManagedObjectContext.self, selector))
        original = method_getImplementation(method)
        typealias Fetch = @convention(c) (NSManagedObjectContext, Selector, NSFetchRequest<NSFetchRequestResult>,
                                         AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSArray?
        let fetch = unsafeBitCast(original, to: Fetch.self)
        typealias FetchBlock = @convention(block) (NSManagedObjectContext, NSFetchRequest<NSFetchRequestResult>,
                                                  AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSArray?
        let block: FetchBlock = { [weak self] context, request, error in
            if let self, self.refusedReads == 0, request.entityName?.hasSuffix("Category") == true {
                self.refusedReads += 1
                error?.pointee = CocoaError(.fileReadCorruptFile) as NSError
                return nil
            }
            return fetch(context, selector, request, error)
        }
        let replacement = imp_implementationWithBlock(block)
        self.replacement = replacement
        method_setImplementation(method, replacement)
    }

    func stop() {
        guard let replacement else { return }
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
        self.replacement = nil
    }
    deinit { stop() }
}
