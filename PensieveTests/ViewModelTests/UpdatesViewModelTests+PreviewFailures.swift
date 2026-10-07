import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testEveryPreviewFailureHidesScratchPaths() throws {
        let fixture = try prepareRealPinnedUpdate()
        let scratch = tempDir + "/preview-scratch"
        for step in ["scratch", "session", "clone", "head", "skills", "vendor", "tree", "admission", "comparison"] {
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
            }
            let git = PreviewFailingGit(step: step)
            let service = SkillInstallService(gitService: git, credentialStore: InMemoryCredentialStore(),
                fileService: spy, scratchRoot: scratch, storeRoot: fixture.storeRoot, lockPath: tempDir + "/sync.lock",
                remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) })
            XCTAssertThrowsError(try service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))) { error in
                XCTAssertFalse(error.localizedDescription.contains(scratch),
                               "\(step): no preview error may reveal its scratch root")
                XCTAssertFalse(error.localizedDescription.contains(tempDir), "\(step): messages must name skill-relative paths")
                if step == "vendor" { XCTAssertTrue(error.localizedDescription.contains(".")) }
                if step == "admission" { XCTAssertTrue(error.localizedDescription.contains("SKILL.md")) }
                if step == "comparison" { XCTAssertTrue(error.localizedDescription.contains("nested/file")) }
                if ["clone", "head", "tree"].contains(step) {
                    let operation = step == "head" ? "HEAD" : step
                    XCTAssertTrue(error.localizedDescription.contains("injected " + operation + " failure"),
                                  "The git failure cause must survive scratch location removal")
                }
            }
        }
    }
}

/// Uses real clones; only the selected failing Git boundary throws a path-bearing production error.
private struct PreviewFailingGit: SkillInstallGitServing {
    let step: String
    let git = GitService()
    func cloneShallow(remote: String, branch: String?, into path: String, credential: GitCredential?) throws {
        if step == "clone" { throw GitError.repositoryUnreadable(path: path, detail: "injected clone failure") }
        try git.cloneShallow(remote: remote, branch: branch, into: path, credential: credential)
    }
    func commitSHA(at path: String) throws -> String {
        if step == "head" { throw GitError.repositoryUnreadable(path: path, detail: "injected HEAD failure") }
        return try git.commitSHA(at: path)
    }
    func currentBranch(at path: String) throws -> String { try git.currentBranch(at: path) }
    func treeHash(at repositoryPath: String, path: String) throws -> String {
        if step == "tree" {
            throw GitError.commandFailed(args: ["-C", repositoryPath, "rev-parse", "HEAD:" + path],
                                         exitCode: 1, stderr: "injected tree failure")
        }
        return try git.treeHash(at: repositoryPath, path: path)
    }
}
