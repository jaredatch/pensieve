import CoreData
import Foundation

/// Observes Core Data's public will-save event beneath the real SwiftData context. After the
/// publication checkpoint enables it, one restoration save in this fixture's persistent store
/// gains an invalid object and fails validation. It changes neither production APIs nor schema,
/// and never affects another database. Rollback discards the deliberately invalid insertion.
final class RestorationSaveFault {
    var refusesRestore = false
    private(set) var refusedSaves = 0
    private var observer: NSObjectProtocol?

    init(root: String) {
        observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave,
            object: nil, queue: nil) { [weak self] notification in
                guard let self, self.refusesRestore, self.refusedSaves == 0,
                      let context = notification.object as? NSManagedObjectContext,
                      let restored = context.insertedObjects.first(where: {
                          $0.entity.name?.hasSuffix("MachineDeployIntent") == true
                      }) else { return }
                var owner = context
                while let parent = owner.parent { owner = parent }
                guard owner.persistentStoreCoordinator?.persistentStores.contains(where: {
                    $0.url?.path == root + "/removal.sqlite"
                }) == true else { return }
                self.refusedSaves += 1
                _ = RestorationValidationFailure(entity: restored.entity, insertInto: context)
            }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

private final class RestorationValidationFailure: NSManagedObject {
    override func validateForInsert() throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError,
            userInfo: [NSLocalizedDescriptionKey: "Restoration save refused"])
    }
}
