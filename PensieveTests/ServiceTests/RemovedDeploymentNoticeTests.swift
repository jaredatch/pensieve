import CoreData
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class RemovedDeploymentNoticeTests: XCTestCase {
    func testRenameAndOfflineDeleteTellOnlyAboutPhysicalDirectProjectRemovals() throws {
        for rename in [true, false] {
            let h = try RemoteRemovalFixture(persistent: true, agents: RemoteRemovalFixture.projectAgents)
            defer { h.cleanup() }
            let direct = try h.project("Website", keyed: false)
            let shared = try h.project("Shared")
            let personal = try h.project("Personal", keyed: false)
            let missing = try h.project("Missing", keyed: false)
            h.intent(project: shared, agents: RemoteRemovalFixture.projectAgents)
            h.intent(agents: [.claudeCode, .cursor])
            try h.deployBefore()
            try h.direct(project: direct, agents: RemoteRemovalFixture.projectAgents)
            try h.direct(project: personal, agents: [.claudeCode, .cursor])
            try h.direct(project: missing, agents: [.grok])
            let folder = h.artifact(.claudeCode, project: "Personal")
            try h.files.deleteFile(at: folder)
            try h.files.writeFile(at: folder + "/mine", content: "User folder")
            let rule = h.artifact(.cursor, project: "Personal")
            try h.files.writeFile(at: rule, content: "User rule")
            let preserved = try h.disk([folder, rule])
            let missingPath = missing.path, directPath = direct.path
            try h.files.replaceItem(at: h.root + "/offline", with: missingPath)
            try h.pull(rename: rename)
            if rename { try h.sync() } else { try h.reopen(); try h.launch() }
            let notice = h.platform.removedDeploymentNotice
            XCTAssertEqual(notice.entries.count, 4)
            XCTAssertEqual(Set(notice.entries.map(\.platform)), Set(RemoteRemovalFixture.projectAgents))
            XCTAssertTrue(notice.entries.allSatisfy {
                $0.slug == "alpha" && $0.projectName == "Website" && $0.projectPath == directPath
            })
            XCTAssertEqual(try h.disk([folder, rule]), preserved)
            try h.assertAbsent(RemoteRemovalFixture.projectAgents, project: "Website")
            try h.files.replaceItem(at: missingPath, with: h.root + "/offline")
            h.convergence.runAfterLaunchIngest()
            XCTAssertEqual(notice.entries.count, 5)
            XCTAssertEqual(notice.entries.filter { $0.projectPath == missingPath }.map(\.platform), [.grok])
            h.convergence.runAfterLaunchIngest()
            XCTAssertEqual(notice.entries.count, 5, "Absent artifacts must not add another notice")
        }
    }

    func testRemovalIsRecordedOnceEvenWhenDeployStateOrHistoryCannotSave() throws {
        for historyFailure in [false, true] {
            let h = try RemoteRemovalFixture(persistent: true)
            defer { h.cleanup() }
            let project = try h.project("Website", keyed: false)
            try h.deployBefore()
            try h.direct(project: project, agents: [.codex])
            let oldID = try h.skill().id
            try h.pull()
            try h.rebuild()
            let fault = RemovedHistorySaveFault(storePath: h.root + "/local.store", enabled: historyFailure)
            defer { fault.stop() }
            let statePath = h.paths.appSupportDir + "/deploy-state.json"
            let stateBytes = try h.files.readFile(at: statePath)
            if !historyFailure {
                try h.files.deleteFile(at: statePath)
                try h.files.createDirectory(at: statePath)
            }
            h.convergence.runAfterLaunchIngest()
            XCTAssertEqual(h.platform.removedDeploymentNotice.entries.count, 1)
            XCTAssertEqual(try h.history(oldID).count, 1, "Failed saves retain retry evidence")
            try h.assertAbsent([.codex], project: "Website")
            if historyFailure { XCTAssertEqual(fault.refusedSaves, 1) } else {
                try h.files.deleteDirectory(at: statePath)
                try h.files.writeFile(at: statePath, content: stateBytes)
            }
            h.convergence.runAfterLaunchIngest()
            XCTAssertEqual(h.platform.removedDeploymentNotice.entries.count, 1)
            XCTAssertTrue(try h.history(oldID).isEmpty)
        }
    }
}

/// Refuses one real SwiftData save deleting deployment history in this fixture's persistent store.
/// It injects a Core Data validation failure only at that save; rollback removes the invalid object.
private final class RemovedHistorySaveFault {
    private var observer: NSObjectProtocol?
    private(set) var refusedSaves = 0

    init(storePath: String, enabled: Bool) {
        observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave,
            object: nil, queue: nil) { [weak self] notification in
                guard let self, enabled, self.refusedSaves == 0,
                      let context = notification.object as? NSManagedObjectContext,
                      let row = context.deletedObjects.first(where: { $0.entity.name?.hasSuffix("DeployRecord") == true })
                else { return }
                var owner = context
                while let parent = owner.parent { owner = parent }
                guard owner.persistentStoreCoordinator?.persistentStores.contains(where: {
                    $0.url?.path == storePath
                }) == true else { return }
                self.refusedSaves += 1
                _ = RemovedHistoryValidationFailure(entity: row.entity, insertInto: context)
            }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

private final class RemovedHistoryValidationFailure: NSManagedObject {
    override func validateForInsert() throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSValidationMissingMandatoryPropertyError,
                      userInfo: [NSLocalizedDescriptionKey: "History save refused"])
    }
}
