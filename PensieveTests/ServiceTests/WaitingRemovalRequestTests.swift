import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class WaitingRemovalRequestTests: XCTestCase {
    func testRecreatedSlugIntentDeploysAndRetiresWaitingWithoutDeleting() throws {
        let h = try WaitingRemovalHarness()
        defer { h.base.cleanup() }
        try h.deploy([.codex])
        let slug = h.base.skill.directoryName
        try h.hideFolder()
        XCTAssertTrue(h.deleteSkill())
        let newSlug = try SkillStore(fileService: h.mapped).createSkill(
            name: "Caller Skill", description: "New skill", body: "# Replacement")
        XCTAssertEqual(newSlug, slug)
        let replacement = Skill(name: "Caller Skill", directoryName: newSlug)
        h.base.context.insert(replacement)
        try h.base.addIntent(platform: .codex, skill: replacement)
        try h.restoreFolder()
        var deletions: [String] = []
        h.base.mapped.beforeArtifactDeletion = { deletions.append($0) }
        _ = h.converge()
        XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)))
        XCTAssertTrue(try h.mapped.readFile(at: h.base.artifact(.codex)).contains("# Replacement"))
        XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
        XCTAssertFalse(deletions.contains(h.base.artifact(.codex)))
        XCTAssertEqual(try h.base.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.skillID), [replacement.id])
    }

    func testDifferentRegistrationRequestsSamePathThroughIntentOrCategory() throws {
        for owner in ["intent", "category"] {
            for alias in [false, true] {
                let h = try WaitingRemovalHarness()
                defer { h.base.cleanup() }
                try h.deploy([.codex])
                try h.hideFolder()
                XCTAssertFalse(h.removeProject().hasFailures)
                try h.restoreFolder()
                h.base.otherProject.path = h.base.project.path
                if alias {
                    let path = h.base.root + "/alias"
                    try h.base.files.createSymlink(at: path, pointingTo: h.base.project.path)
                    h.base.otherProject.path = path
                }
                if owner == "intent" { try h.base.addIntent(platform: .codex, project: h.base.otherProject) } else {
                    let category = Pensieve.Category(name: "Surviving owner")
                    category.skillSlugs = [h.base.skill.directoryName]
                    category.projectKeys = [h.base.otherProject.identityKey!]
                    h.base.context.insert(category)
                }
                try h.base.context.save()
                var deleted: [String] = []
                h.base.mapped.beforeArtifactDeletion = { deleted.append($0) }
                _ = h.converge()
                XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(.codex)), "\(owner)/\(alias)")
                XCTAssertTrue(try h.vm.waitingRemovalStore.read().isEmpty)
                XCTAssertTrue(deleted.isEmpty)
            }
        }
    }

    func testEveryDesiredReadFailurePausesAllWaitingEntries() throws {
        for failure in ["skills", "projects", "intents", "categories", "paths"] {
            let h = try WaitingRemovalHarness(platforms: [.claudeCode, .codex])
            defer { h.base.cleanup() }
            try h.deploy([.claudeCode, .codex])
            try h.hideFolder()
            XCTAssertFalse(h.removeProject().hasFailures)
            try h.restoreFolder()
            if failure == "paths" {
                try h.base.addIntent(platform: .codex, project: h.base.otherProject)
                h.mapped.beforePathResolution = { _ in throw CocoaError(.fileReadNoPermission) }
            }
            let bytes = try h.base.files.readData(at: h.storePath)
            let waiting = WaitingRemovalReconciler(store: h.vm.waitingRemovalStore, fileService: h.mapped,
                platformVM: h.vm, machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
                stateFetcher: WaitingDesiredReadFault(failing: failure))
            XCTAssertTrue(waiting.reconcile(context: h.base.context).hasFailures, failure)
            XCTAssertEqual(try h.base.files.readData(at: h.storePath), bytes)
            for platform in [PlatformTarget.claudeCode, .codex] {
                XCTAssertTrue(h.base.files.isSymlink(at: h.base.artifact(platform)))
            }
        }
    }
}
