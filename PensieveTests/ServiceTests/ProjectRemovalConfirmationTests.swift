import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class ProjectRemovalConfirmationTests: XCTestCase {
    func testConfirmationCountsOwnedLocalArtifactsAndCancelChangesNothing() throws {
        let h = try ProjectFolderCallerHarness()
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        for platform in [PlatformTarget.claudeCode, .grok, .codex, .cursor] { try h.addIntent(platform: platform) }
        XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
        let paths = [PlatformTarget.claudeCode, .grok, .codex, .cursor].map {
            h.platformVM.artifactPath(skill: h.skill, platform: $0, target: .project(h.project))
        }
        try h.files.deleteFile(at: paths[2])
        try h.files.createSymlink(at: paths[2], pointingTo: h.otherProject.path)
        try h.files.writeFile(at: h.project.path + "/.cursor/rules/teammate.mdc",
                              content: "---\n# pensieve: managed\n---\nKeep")
        let manifest = ManifestService(fileService: h.files)
        try manifest.write(try manifest.snapshot(from: h.context), toRoot: h.root + "/sync")
        let manifestPath = h.root + "/sync/manifest/deploys/" + ProjectIntentHarness.localID + "/"
            + h.skill.directoryName + ".yaml"
        let stateBytes = try h.files.readFile(at: h.root + "/support/deploy-state.json")
        let manifestBytes = try h.files.readFile(at: manifestPath)
        let ledgerKeys = Set(try h.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.key))
        let name = h.project.name
        let model = ProjectRemovalModel()
        model.request(h.project, platformVM: h.platformVM, context: h.context)
        XCTAssertEqual(model.preview?.title, "Remove “\(name)”?" )
        XCTAssertEqual(model.preview?.artifactCount, 3, "Overlapping history/state/ledger evidence counts each artifact once")
        XCTAssertTrue(model.preview?.message.contains("3 skill links and rules") == true)
        XCTAssertTrue(model.preview?.message.contains("Your files stay.") == true)
        XCTAssertNil(model.error)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2, "Choosing Remove only prepares confirmation")
        for path in paths { XCTAssertTrue(try h.files.entryExistsWithoutFollowingLinks(at: path)) }
        model.cancel()
        XCTAssertNil(model.project)
        XCTAssertNil(model.preview)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
        XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<IntentAssignment>()).map(\.key)), ledgerKeys)
        XCTAssertEqual(try h.files.readFile(at: h.root + "/support/deploy-state.json"), stateBytes)
        XCTAssertEqual(try h.files.readFile(at: manifestPath), manifestBytes)
        model.confirm { _, _ in XCTFail("Cancel must prevent a later confirm from invoking removal"); return BatchResult() }
    }

    func testZeroAndMissingFolderConfirmationsAndUncheckableFolderRetention() throws {
        for status in ["empty", "missing", "uncheckable"] {
            let h = try ProjectFolderCallerHarness(installed: [.cursor])
            defer { h.cleanup() }
            let id = h.project.id
            var retainedRule: String?
            if status != "empty" {
                try h.files.createDirectory(at: h.project.path)
                try h.addIntent(platform: .cursor)
                XCTAssertFalse(h.intent.reconcile(context: h.context).hasFailures)
                let path = h.platformVM.artifactPath(skill: h.skill, platform: .cursor, target: .project(h.project))
                if status == "missing" {
                    let offline = h.root + "/offline-volume"
                    try h.files.replaceItem(at: offline, with: h.project.path)
                    retainedRule = offline + String(path.dropFirst(h.project.path.count))
                } else {
                    retainedRule = path
                    h.mapped.beforeProjectProbe = { candidate in
                        if candidate == h.project.path { throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
                    }
                }
            } else {
                try h.files.createDirectory(at: h.project.path)
            }
            let model = ProjectRemovalModel()
            model.request(h.project, platformVM: h.platformVM, context: h.context)
            if status == "uncheckable" {
                XCTAssertNil(model.project)
                XCTAssertTrue(model.error?.contains(h.project.path) == true)
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Project>()), 2)
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
            } else {
                let preview = try XCTUnwrap(model.preview)
                XCTAssertEqual(preview.artifactCount, 0)
                XCTAssertEqual(preview.folderIsMissing, status == "missing")
                XCTAssertTrue(preview.message.contains(status == "missing"
                    ? "can't reach this folder" : "No skill links or rules will be removed"))
                model.confirm { project, plan in
                    removeRegisteredProject(project, categoryStore: CategoryStore(), reconciler: h.category,
                        manifestService: ManifestService(fileService: h.files), manifestRoot: h.root + "/sync",
                        platformVM: h.platformVM, localMachineID: ProjectIntentHarness.localID, preparedPlan: plan,
                        context: h.context)
                }
                XCTAssertNil(model.error)
                XCTAssertFalse(try h.context.fetch(FetchDescriptor<Project>()).contains { $0.id == id })
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
            }
            if let retainedRule { XCTAssertTrue(h.files.fileExists(at: retainedRule)) }
        }
    }
}
