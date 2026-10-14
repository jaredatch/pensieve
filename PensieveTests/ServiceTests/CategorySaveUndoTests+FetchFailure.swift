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
        let rebuilding = ModelContext(container)
        let fault = try CategoryFetchFault(in: rebuilding)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Pensieve.Category>()).count, 2,
                       "An unrelated context must not consume the rebuild's fault")
        XCTAssertEqual(fault.refusedReads, 0)
        let result = StoreRebuildService().rebuild(fromRoot: h.root, context: rebuilding)
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

/// Refuse one native Core Data category query in the supplied SwiftData context. A synchronous
/// priming fetch identifies its backing context on the installing thread; other contexts and
/// entity types always use the original implementation. The counter is synchronized. Each host
/// runs one case at a time; stop restores the method after the rebuild or queue acceptance completes.
final class CategoryFetchFault {
    private let method: Method
    private let original: IMP
    private var replacement: IMP?
    private let lock = NSLock()
    private weak var target: NSManagedObjectContext?
    private let installingThread = Thread.current
    private var priming = true
    private var refusals = 0
    var refusedReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return refusals
    }

    init(in modelContext: ModelContext) throws {
        let selector = NSSelectorFromString("executeFetchRequest:error:")
        method = try XCTUnwrap(class_getInstanceMethod(NSManagedObjectContext.self, selector))
        original = method_getImplementation(method)
        typealias Fetch = @convention(c) (NSManagedObjectContext, Selector, NSFetchRequest<NSFetchRequestResult>,
                                         AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSArray?
        let fetch = unsafeBitCast(original, to: Fetch.self)
        typealias FetchBlock = @convention(block) (NSManagedObjectContext, NSFetchRequest<NSFetchRequestResult>,
                                                  AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSArray?
        let block: FetchBlock = { [weak self] context, request, error in
            if let self, self.shouldRefuse(context, request: request) {
                error?.pointee = CocoaError(.fileReadCorruptFile) as NSError
                return nil
            }
            return fetch(context, selector, request, error)
        }
        let replacement = imp_implementationWithBlock(block)
        self.replacement = replacement
        method_setImplementation(method, replacement)
        do {
            _ = try modelContext.fetch(FetchDescriptor<Pensieve.Category>())
            _ = try XCTUnwrap(target, "The priming fetch must identify the rebuild's native context")
            lock.lock()
            priming = false
            lock.unlock()
        } catch { stop(); throw error }
    }

    private func shouldRefuse(_ context: NSManagedObjectContext,
                              request: NSFetchRequest<NSFetchRequestResult>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard request.entityName?.hasSuffix("Category") == true else { return false }
        if priming {
            if Thread.current === installingThread { target = context }
            return false
        }
        guard context === target, refusals == 0 else { return false }
        refusals += 1
        return true
    }

    func stop() {
        guard let replacement else { return }
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
        self.replacement = nil
    }
    deinit { stop() }
}

extension ManifestSaveTests {
    @MainActor
    func checkAcceptedCategoryFetchFailure() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let completed = TestWait.Gate(owner: self)
        defer { completed.open() }
        h.recording.afterRebuildSnapshot = { try completed.wait() }
        h.categories.rename(h.local, to: "Saved", context: h.context)
        await TestWait.until(failureMessage: "The scan must finish before acceptance is faulted") {
            completed.waiterCount == 1
        }
        let fault = try CategoryFetchFault(in: h.context)
        defer { fault.stop() }
        completed.open()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(fault.refusedReads, 1, "Acceptance must reach the category fetch fault")
        let message = try XCTUnwrap(h.messages.lines.last, "Acceptance must report the rebuild failure")
        XCTAssertTrue(message.contains("rebuilding the local store failed"), message)
        XCTAssertTrue(message.contains("categories"), message)
        XCTAssertTrue(message.contains(CocoaError(.fileReadCorruptFile).localizedDescription), message)
        XCTAssertEqual(h.local.name, "Saved", "The published edit stays saved")
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).categories.map(\.name), ["Saved", "ZDelete"])
    }
}
