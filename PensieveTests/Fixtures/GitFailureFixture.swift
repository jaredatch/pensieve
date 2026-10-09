import Foundation
@testable import Pensieve

/// Stand-in subprocesses run only in this temporary tree. The trace and switch live outside the store,
/// so byte snapshots include all store files (including `.git`) without counting test instrumentation.
struct GitFailureFixture {
    let base = TestTemporaryDirectory.path + "PensieveGitFailure-" + UUID().uuidString
    let files = FileService()
    var root: String { base + "/store" }
    var support: String { base + "/support" }
    var script: String { base + "/git" }
    var trace: String { base + "/calls" }
    var credentialTrace: String { base + "/credentials" }
    var failureSwitch: String { base + "/fail" }
    var paths: AppRuntimePaths { AppRuntimePaths(storeRoot: root, appSupportDir: support) }

    init() throws {
        try files.createDirectory(at: root)
        try files.createDirectory(at: support)
    }

    func remove() throws { try files.deleteDirectory(at: base) }

    func executable(_ body: String, fileService: FileServiceProtocol = FileService()) throws -> GitService {
        try files.writeExecutableFile(at: script, content: "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(trace)'\n" + body + "\n")
        return GitService(
            fileService: fileService,
            askpassHelperPath: support + "/askpass",
            executablePath: script
        )
    }

    /// Records each subprocess's actual argv and whether its password environment variable matches
    /// the expected test token. The receipt contains only a marker, never the environment's token.
    /// Responses exercise history's branch, missing-branch/tag fallback and missing-object fetches;
    /// no command delegates to real git. Askpass writes are mapped into this temporary tree.
    func credentialRecordingExecutable(expectedToken: String) throws -> GitService {
        let fileService = LinkServiceCanonicalDirectoryFileService(
            wrapped: files,
            pathMappings: [((TestPaths.gitAskpassHelperPath), support + "/askpass")],
            physicalSandbox: base
        )
        return try executable("""
            marker=missing
            if [ "$PENSIEVE_GIT_PASSWORD" = '\(expectedToken)' ]; then marker=received; fi
            printf '%s\\t%s\\n' "$marker" "$*" >> '\(credentialTrace)'
            repository='\(root)'
            \(FakeGitScript.skipGlobalOptions)
            case "$1 $2" in
              clone*) for destination in "$@"; do :; done; mkdir -p "$destination/.git" ;;
              'ls-remote --symref') printf 'ref: refs/heads/main\\tHEAD\\n' ;;
              ls-remote*) printf '%s\\trefs/heads/main\\n' '\(String(repeating: "a", count: 40))' ;;
              'rev-parse --is-shallow-repository') printf 'true\\n' ;;
              'rev-parse --path-format=absolute') printf '%s/.git/%s\\n' "$repository" "$4" ;;
              rev-parse*|rev-list*) printf '%s\\n' '\(String(repeating: "a", count: 40))' ;;
              'cat-file -e') exit 1 ;;
              fetch*)
                case "$*" in
                  *refs/heads/v1*) printf "fatal: couldn't find remote ref refs/heads/v1\\n" >&2; exit 128 ;;
                esac ;;
            esac
            exit 0
            """, fileService: fileService)
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
        let git = GitService(askpassHelperPath: support + "/askpass")
        try git.initRepository(at: root)
        try files.writeFile(at: root + "/skills/example/SKILL.md",
                            content: "---\nname: Example\ndescription: Fixture\n---\nBody\n")
        try ManifestService().write(
            ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                             categories: [], projects: [], skills: []), toRoot: root
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
