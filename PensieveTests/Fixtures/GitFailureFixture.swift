import Foundation
@testable import Pensieve

/// Stand-in subprocesses run only in this temporary tree. The trace and switch live outside the store,
/// so byte snapshots include all store files (including `.git`) without counting test instrumentation.
struct GitFailureFixture {
    let base = NSTemporaryDirectory() + "PensieveGitFailure-" + UUID().uuidString
    let files = FileService()
    var root: String { base + "/store" }
    var support: String { base + "/support" }
    var script: String { base + "/git" }
    var trace: String { base + "/calls" }
    var failureSwitch: String { base + "/fail" }
    var paths: AppRuntimePaths { AppRuntimePaths(storeRoot: root, appSupportDir: support) }

    init() throws {
        try files.createDirectory(at: root)
        try files.createDirectory(at: support)
    }

    func remove() throws { try files.deleteDirectory(at: base) }

    func executable(_ body: String) throws -> GitService {
        try files.writeExecutableFile(at: script, content: "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(trace)'\n" + body + "\n")
        return GitService(executablePath: script)
    }

    func broken(_ state: GitUsability) throws -> GitService {
        let output: String
        let exit: Int
        switch state {
        case .licenseNotAccepted:
            output = "You have not agreed to the Xcode license. Run sudo xcodebuild -license."; exit = 69
        case .developerToolsMissing:
            output = "xcrun: error: invalid active developer path (/missing)"; exit = 1
        case let .failed(detail): output = detail.text; exit = 42
        case .usable: output = "git version fixture"; exit = 0
        }
        return try executable("printf '%s\\n' '\(output)' >&2\nexit \(exit)")
    }

    func seedRepository(remote: String? = "https://fixture.test/store.git") throws {
        let git = GitService()
        try git.initRepository(at: root)
        try files.writeFile(at: root + "/skills/example/SKILL.md",
                            content: "---\nname: Example\ndescription: Fixture\n---\nBody\n")
        try ManifestService().write(
            ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                             categories: [], scenarios: [], projects: [], skills: []), toRoot: root
        )
        try git.stageAllAndCommit(at: root, message: "fixture")
        if let remote { try git.setRemote(remote, at: root) }
    }

    func snapshot(_ directory: String? = nil) throws -> [String: Data] {
        let directory = directory ?? root
        var result: [String: Data] = [:]
        for entry in try files.listDirectory(at: directory) {
            let path = directory + "/" + entry
            if files.isSymlink(at: path) {
                result[path] = Data(try files.symlinkTarget(at: path).utf8)
            } else if files.directoryExists(at: path) {
                result[path] = Data()
                result.merge(try snapshot(path)) { first, _ in first }
            } else {
                result[path] = try files.readData(at: path)
            }
        }
        return result
    }
}
