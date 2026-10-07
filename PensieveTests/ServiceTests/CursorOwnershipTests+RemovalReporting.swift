import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testSelectionAndDeletionKeepOwnershipErrorsBeforeDeleteErrors() throws {
        for deletion in [false, true] {
            let harness = try contextAndVM()
            let project = reviewProject(harness.context)
            let target = DeployTarget.project(project)
            let link = artifactPath(.claudeCode, project: project.path)
            let rule = artifactPath(.cursor, project: project.path)
            for platform in [PlatformTarget.claudeCode, .cursor] {
                let path = artifactPath(platform, project: project.path)
                try plant(owned: true, legacy: false, platform: platform, path: path, project: project.path)
                try reviewRecord(harness.state, path: path, platform: platform, target: target)
            }
            mapped.beforeRuleRead = { path in
                if path == rule { throw NSError(domain: NSPOSIXErrorDomain, code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Ownership lookup failed"]) }
            }
            mapped.beforeArtifactDeletion = { path in
                if path == link { throw NSError(domain: NSPOSIXErrorDomain, code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Artifact delete failed"]) }
            }
            if deletion {
                let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
                    manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
                XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
                    projects: [project], context: harness.context))
                let message = try XCTUnwrap(library.deletionNotice?.message)
                let ownership = try XCTUnwrap(message.range(of: "Ownership lookup failed"))
                let artifact = try XCTUnwrap(message.range(of: "Artifact delete failed"))
                XCTAssertLessThan(ownership.lowerBound, artifact.lowerBound,
                                  "Removal messages keep ownership failures before artifact deletion failures")
            } else {
                let batch = harness.vm.removeSelection(skills: [skill], platforms: [.claudeCode, .cursor], target: target)
                XCTAssertEqual(batch.failureCount, 2)
                XCTAssertEqual(batch.failures.map(\.platform), [.cursor, .claudeCode],
                               "Selection reports ownership failures before deletion failures")
            }
            XCTAssertTrue(try mapped.entryExistsWithoutFollowingLinks(at: link))
            XCTAssertTrue(try mapped.entryExistsWithoutFollowingLinks(at: rule))
            mapped.beforeRuleRead = nil
            mapped.beforeArtifactDeletion = nil
            try mapped.deleteFile(at: link)
            try mapped.deleteFile(at: rule)
        }
    }
}
