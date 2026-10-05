import XCTest
@testable import Pensieve

final class UpstreamHistoryServiceTests: XCTestCase {
    struct RawResult {
        let stdout: String
        let stderr: String
        let exit: Int32
    }

    var tempDir: String!
    var scratchRoot: String!
    var localDirectory: String!
    var fileService: FileService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveUpstreamHistoryTests-\(UUID().uuidString)"
        scratchRoot = tempDir + "/scratch"
        localDirectory = tempDir + "/local"
        try FileManager.default.createDirectory(atPath: localDirectory, withIntermediateDirectories: true)
        fileService = FileService()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @discardableResult
    func rawGit(_ args: [String], environment additions: [String: String] = [:]) throws -> RawResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        additions.forEach { environment[$0] = $1 }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RawResult(
            stdout: String(bytes: stdoutData, encoding: .utf8) ?? "",
            stderr: String(bytes: stderrData, encoding: .utf8) ?? "",
            exit: process.terminationStatus
        )
    }

    func makeRepository() throws -> String {
        let path = tempDir + "/repository"
        let result = try rawGit(["init", "--initial-branch=main", path])
        XCTAssertEqual(result.exit, 0, result.stderr)
        return path
    }

    func write(_ relativePath: String, text: String, in root: String) throws {
        try fileService.writeFile(at: root + "/" + relativePath, content: text)
    }

    func write(_ relativePath: String, data: Data, in root: String) throws {
        let path = root + "/" + relativePath
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: data))
    }

    @discardableResult
    func commit(_ repository: String, message: String, timestamp: Int? = nil) throws -> String {
        let add = try rawGit(["-C", repository, "add", "-A"])
        XCTAssertEqual(add.exit, 0, add.stderr)
        var environment: [String: String] = [:]
        if let timestamp {
            let value = "@\(timestamp) +0000"
            environment["GIT_AUTHOR_DATE"] = value
            environment["GIT_COMMITTER_DATE"] = value
        }
        let result = try rawGit([
            "-C", repository, "-c", "user.email=history@example.com",
            "-c", "user.name=History Author", "commit", "-m", message
        ], environment: environment)
        XCTAssertEqual(result.exit, 0, result.stderr)
        return try revision("HEAD", in: repository)
    }

    func revision(_ value: String, in repository: String) throws -> String {
        let result = try rawGit(["-C", repository, "rev-parse", value])
        XCTAssertEqual(result.exit, 0, result.stderr)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stableHash(at directory: String) throws -> String {
        try SkillInstallService(
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: tempDir + "/install-scratch",
            storeRoot: tempDir + "/store",
            lockPath: tempDir + "/sync.lock",
            remoteValidator: fixtureValidator
        ).stableContentHash(at: directory)
    }

    var fixtureValidator: InstallRemotePolicy.Validator {
        { stored in ValidatedInstallRemote(repo: stored, cloneRemote: stored) }
    }

    func service(git: UpstreamHistoryGitServing? = nil,
                 credentials: CredentialStoreProtocol = InMemoryCredentialStore(),
                 contentHasher: SkillContentHashing? = nil,
                 commitWindow: Int = UpstreamHistoryService.commitWindow,
                 rowWindow: Int = UpstreamHistoryService.rowWindow,
                 textByteLimit: Int = UpstreamHistoryService.textByteLimit,
                 baselineFileLimit: Int = UpstreamHistoryService.baselineFileLimit,
                 baselineByteLimit: Int = UpstreamHistoryService.baselineByteLimit)
        -> UpstreamHistoryService {
        UpstreamHistoryService(
            gitService: git ?? GitService(fileService: fileService),
            credentialStore: credentials,
            fileService: fileService,
            contentHasher: contentHasher ?? SkillInstallService(
                credentialStore: credentials,
                fileService: fileService,
                scratchRoot: tempDir + "/install-scratch",
                storeRoot: tempDir + "/store",
                lockPath: tempDir + "/sync.lock",
                remoteValidator: fixtureValidator
            ),
            scratchRoot: scratchRoot,
            commitWindow: commitWindow,
            rowWindow: rowWindow,
            textByteLimit: textByteLimit,
            baselineFileLimit: baselineFileLimit,
            baselineByteLimit: baselineByteLimit,
            remoteValidator: fixtureValidator
        )
    }

    func origin(repo: String, path: String = "skills/demo", ref: String = "main",
                installedCommit: String, contentHash: String) -> InstalledOrigin {
        InstalledOrigin(
            repo: repo,
            path: path,
            ref: ref,
            installedCommit: installedCommit,
            installedTree: "tree",
            contentHash: contentHash,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func assertScratchEmpty(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(fileService.directoryExists(at: scratchRoot), file: file, line: line)
        XCTAssertEqual(try fileService.listDirectory(at: scratchRoot), [], file: file, line: line)
    }
}

final class RecordingUpstreamHistoryGit: UpstreamHistoryGitServing {
    struct HeadRequest {
        let remote: String
        let ref: String
        let credential: GitCredential?
    }

    var result: Result<UpstreamHistoryGitSnapshot, Error>
    var remoteHeadResult: Result<String?, Error> = .success(nil)
    var createScratchArtifact = false
    private(set) var requests: [UpstreamHistoryGitRequest] = []
    private(set) var headRequests: [HeadRequest] = []

    init(result: Result<UpstreamHistoryGitSnapshot, Error>) {
        self.result = result
    }

    func upstreamHistory(_ request: UpstreamHistoryGitRequest) throws -> UpstreamHistoryGitSnapshot {
        requests.append(request)
        if createScratchArtifact {
            try FileService().writeFile(at: request.repositoryPath + "/FETCH_HEAD", content: "partial")
        }
        return try result.get()
    }

    func remoteHead(remote: String, ref: String, credential: GitCredential?) throws -> String? {
        headRequests.append(HeadRequest(remote: remote, ref: ref, credential: credential))
        return try remoteHeadResult.get()
    }
}

struct FixedContentHasher: SkillContentHashing {
    let value: String

    func stableContentHash(at directory: String,
                           excludingTopLevelGitMetadata: Bool) throws -> String { value }
}
