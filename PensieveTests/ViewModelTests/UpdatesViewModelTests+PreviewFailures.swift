import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testEveryPreviewFailureHidesScratchPaths() throws {
        let fixture = try prepareRealPinnedUpdate()
        let scratch = tempDir + "/preview-scratch"
        let steps = ["scratch", "session", "clone", "head", "skills", "vendor", "tree", "admission",
                     "comparison", "comparison-raw"]
        for step in steps {
            let spy = ImportBoundedReadSpy()
            func failure(_ path: String) -> NSError {
                NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                    NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "Denied at " + path
                ])
            }
            spy.creationFailure = { path in
                if (step == "scratch" && path == scratch) || (step == "session" && path != scratch) {
                    throw failure(path)
                }
            }
            spy.entryFailure = { path in
                if ["skills", "vendor"].contains(step), path.hasPrefix(scratch + "/"), path.hasSuffix("/" + step) {
                    throw failure(path)
                }
            }
            spy.prefixFailure = { if step == "admission" { throw failure($0) } }
            spy.comparisonFailure = { _, upstream in
                if step == "comparison" { throw failure(upstream + "/nested/file") }
                if step == "comparison-raw" {
                    throw GitError.commandFailed(args: [upstream], exitCode: 1,
                                                 stderr: "remote: untrusted comparison " + upstream)
                }
            }
            let git = PreviewFailingGit(step: step)
            let service = SkillInstallService(gitService: git, credentialStore: InMemoryCredentialStore(),
                fileService: spy, scratchRoot: scratch, storeRoot: fixture.storeRoot, lockPath: tempDir + "/sync.lock",
                remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) })
            XCTAssertThrowsError(try service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))) { error in
                assertPreviewFailure(error, step: step, scratch: scratch)
            }
        }
    }

    private func assertPreviewFailure(_ error: Error, step: String, scratch: String) {
        XCTAssertFalse(error.localizedDescription.contains(scratch),
                       "\(step): no preview error may reveal its scratch root")
        XCTAssertFalse(error.localizedDescription.contains(tempDir),
                       "\(step): messages must name skill-relative paths")
        XCTAssertFalse(error.localizedDescription.contains("remote:"), "Upstream-controlled stderr must never appear")
        XCTAssertFalse(error.localizedDescription.contains("untrusted"), "Upstream-controlled error text must never appear")
        if step == "vendor" { XCTAssertTrue(error.localizedDescription.contains(".")) }
        if step == "admission" { XCTAssertTrue(error.localizedDescription.contains("SKILL.md")) }
        if step == "comparison" { XCTAssertTrue(error.localizedDescription.contains("nested/file")) }
        if step == "comparison-raw" {
            XCTAssertEqual(error.localizedDescription, "Couldn't compare the skill's files.",
                           "An unclassified comparison error must name only its operation")
        }
        if ["clone", "head", "tree"].contains(step) {
            let expected = step == "clone" ? "Couldn't fetch the upstream repository."
                : step == "head" ? "Couldn't verify the pinned commit." : "Couldn't check the upstream tree hash."
            XCTAssertEqual(error.localizedDescription, expected, "Preview git failures must name only the operation")
        }
    }

}

/// Uses real clones; only the selected failing Git boundary throws a path-bearing production error.
private struct PreviewFailingGit: SkillInstallGitServing {
    let step: String
    let git = GitService()
    func cloneShallow(remote: String, branch: String?, into path: String, credential: GitCredential?) throws {
        if step == "clone" { throw GitError.repositoryUnreadable(path: path, detail: "remote: untrusted clone text " + path) }
        try git.cloneShallow(remote: remote, branch: branch, into: path, credential: credential)
    }
    func commitSHA(at path: String) throws -> String {
        if step == "head" { throw GitError.repositoryUnreadable(path: path, detail: "remote: untrusted HEAD text " + path) }
        return try git.commitSHA(at: path)
    }
    func currentBranch(at path: String) throws -> String { try git.currentBranch(at: path) }
    func treeHash(at repositoryPath: String, path: String) throws -> String {
        if step == "tree" {
            throw GitError.commandFailed(args: ["-C", repositoryPath, "rev-parse", "HEAD:" + path],
                                         exitCode: 1, stderr: "remote: untrusted tree text " + repositoryPath)
        }
        return try git.treeHash(at: repositoryPath, path: path)
    }
}
