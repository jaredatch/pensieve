import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func secondReviewModel(_ harness: OwnershipRouteHarness) -> DeployIntentModel {
        let intent = reviewIntent(harness.vm)
        let manifest = ManifestService(fileService: files)
        return DeployIntentModel(platformVM: harness.vm, dependencies: DeployIntentDependencies(
            identity: ProjectIntentIdentityStub(id: ProjectIntentHarness.localID),
            stateService: MachineStateService(fileService: mapped), root: root + "/store",
            writeManifest: { try manifest.write(try manifest.snapshot(from: $0), toRoot: self.root + "/store") },
            notifier: {}, reconcile: { intent.reconcile(context: $0) }, lockPath: root + "/support/intent.lock"))
    }

    @MainActor
    func testUnselectAdmitsProjectBeforeRetiringRecords() throws {
        for missing in [true, false] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let target = DeployTarget.project(project)
            let path = artifactPath(.cursor, project: project.path)
            try reviewRecord(harness.state, path: path, target: target)
            if missing {
                harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor", projectID: project.id))
                try files.deleteDirectory(at: project.path)
            } else {
                mapped.beforeProjectProbe = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            }
            try harness.context.save()
            let before = try harness.state.read()
            let result = try secondReviewModel(harness).set(false, skill: skill, platform: .cursor,
                target: target, context: harness.context)
            XCTAssertEqual(result.failureCount, missing ? 0 : 1)
            XCTAssertEqual(try harness.state.read(), before)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), missing ? 1 : 0)
            if !missing { XCTAssertNotNil(result.failures.first?.projectFolderError) }
            mapped.beforeProjectProbe = nil
            try files.createDirectory(at: project.path)
        }
    }

    @MainActor
    func testDirectUnselectPreservesForeignRuleWithoutReportingRemoval() throws {
        let harness = try contextAndVM()
        let project = reviewProject(harness.context)
        project.identityKey = nil
        let path = artifactPath(.cursor, project: project.path)
        try mapped.writeFile(at: path, content: "User rule")
        try reviewRecord(harness.state, path: path, target: .project(project))
        let result = try secondReviewModel(harness).set(false, skill: skill, platform: .cursor,
            target: .project(project), context: harness.context)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(try harness.state.read().records.isEmpty)
        XCTAssertEqual(try mapped.readFile(at: path), "User rule")
    }

    @MainActor
    func testUnselectDoesNotRecheckPairAlreadyRetiredByReconciler() throws {
        for projectScope in [false, true] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let target: DeployTarget = projectScope ? .project(project) : .userWide
            let path = artifactPath(.cursor, project: target.project?.path)
            try mapped.writeFile(at: path, content: "User rule")
            try reviewRecord(harness.state, path: path, target: target)
            harness.context.insert(IntentAssignment(skillID: skill.id, platformRaw: "cursor", projectID: target.project?.id))
            try harness.context.save()
            var reads = 0
            mapped.beforeRuleRead = { _ in
                reads += 1
                // One ownership check reads the header and compares legacy bytes. The next read fails.
                if reads > 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            }
            let result = try secondReviewModel(harness).set(false, skill: skill, platform: .cursor,
                target: target, context: harness.context)
            XCTAssertTrue(result.outcomes.isEmpty, "An already retired pair must not become a later read failure")
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
            XCTAssertTrue(try harness.state.read().records.isEmpty)
            mapped.beforeRuleRead = nil
            XCTAssertEqual(try mapped.readFile(at: path), "User rule")
        }
    }
}
