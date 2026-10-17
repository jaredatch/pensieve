import CoreData
import SwiftData
import XCTest

/// Refuse one actual native save, scoped to the queue's submitting context. The fetch spy only
/// identifies that context; it never refuses a query. Restored before any recovery writer runs.
final class ContextSaveFault {
    private let identity: CategoryFetchFault
    private let method: Method
    private let original: IMP
    private var replacement: IMP?
    private(set) var refusedSaves = 0

    init(in context: ModelContext) throws {
        identity = try CategoryFetchFault(in: context, entityName: "UnusedEntity")
        let selector = NSSelectorFromString("save:")
        method = try XCTUnwrap(class_getInstanceMethod(NSManagedObjectContext.self, selector))
        original = method_getImplementation(method)
        typealias Save = @convention(c) (NSManagedObjectContext, Selector,
                                        AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let save = unsafeBitCast(original, to: Save.self)
        typealias SaveBlock = @convention(block) (NSManagedObjectContext,
                                                 AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let block: SaveBlock = { [weak self] target, error in
            if let self, target === self.identity.target, self.refusedSaves == 0 {
                self.refusedSaves += 1
                error?.pointee = CocoaError(.fileWriteNoPermission) as NSError
                return false
            }
            return save(target, selector, error)
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
        identity.stop()
    }
    deinit { stop() }
}
