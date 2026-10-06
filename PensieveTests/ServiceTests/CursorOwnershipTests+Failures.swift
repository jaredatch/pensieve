import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    func testUnreadableMarkedRuleFailsDeployAndRemovalAndKeepsBytes() throws {
        for project: String? in [nil, root + "/project"] {
            let path = compiler.outputPath(skill: skill, projectPath: project)
            let physical = project == nil ? root + "/user/rules/" + skill.directoryName + ".mdc" : path
            let text = "---\n# pensieve: managed\n---\nKeep"
            try mapped.writeFile(at: path, content: text)
            XCTAssertEqual(chmod(physical, 0o000), 0)
            defer { XCTAssertEqual(chmod(physical, 0o600), 0) }
            XCTAssertThrowsError(try compiler.compile(skill: skill, projectPath: project)) { assertCouldNotCheck($0, path: path) }
            XCTAssertThrowsError(try compiler.remove(skill: skill, projectPath: project)) { assertCouldNotCheck($0, path: path) }
            XCTAssertEqual(chmod(physical, 0o600), 0)
            XCTAssertEqual(try mapped.readFile(at: path), text)
        }
    }

    @MainActor
    func testReadFailuresThroughRemovalRoutesRetainOwnershipAndSkill() throws {
        for route in ["single", "bulk", "category", "intent", "skill"] {
            let harness = try contextAndVM()
            let context = harness.context, vm = harness.vm, state = harness.state
            let project = Project(name: "Project", path: root + "/project")
            project.identityKey = "github.com/owner/project"
            context.insert(project)
            let path = compiler.outputPath(skill: skill, projectPath: project.path)
            let text = "---\n# pensieve: managed\n---\nKeep"
            try mapped.writeFile(at: path, content: text)
            try state.upsert(DeployStateRecord(slug: skill.directoryName, platform: "cursor", scope: "project",
                projectIdentityKey: project.identityKey, artifactPath: path, recordedAt: "2026-10-05T00:00:00Z"))
            context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor", projectID: project.id))
            context.insert(SkillProjectAssignment(skillID: skill.id, projectID: project.id, platform: .cursor))
            try context.save()
            mapped.beforeRuleRead = { candidate in
                if candidate == path { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            }
            switch route {
            case "single":
                vm.remove(skill: skill, platform: .cursor, target: .project(project))
                XCTAssertTrue(vm.error?.contains("Could not check ownership") == true)
            case "bulk":
                XCTAssertEqual(vm.removeOwnedBatch(
                    pairs: DeployRemovalPair.expand(skills: [skill], platforms: [.cursor]),
                    target: .project(project)).failureCount, 1)
            case "category":
                // No competing intent owner: the category must attempt removal and keep its ledger on failure.
                for row in try context.fetch(FetchDescriptor<IntentAssignment>()) { context.delete(row) }
                try context.save()
                XCTAssertEqual(CategoryReconciler(platformVM: vm).reconcile(context: context).failureCount, 1)
            case "intent":
                for row in try context.fetch(FetchDescriptor<SkillProjectAssignment>()) { context.delete(row) }
                try context.save()
                XCTAssertEqual(IntentReconciler(platformVM: vm,
                    machineIdentity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
                    handoverIsComplete: { true }).reconcile(context: context).failureCount, 1)
            default:
                let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
                    manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
                XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: vm,
                                                       projects: [project], context: context))
                XCTAssertTrue(library.deletionNotice?.message.contains(path) == true)
                XCTAssertTrue(library.deletionNotice?.message.contains("links and rules") == true)
            }
            mapped.beforeRuleRead = nil
            XCTAssertEqual(try mapped.readFile(at: path), text)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Skill>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IntentAssignment>()), route == "category" ? 0 : 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), route == "intent" ? 0 : 1)
            XCTAssertEqual(try state.read().records.map(\.artifactPath), [path])
        }
    }
}
