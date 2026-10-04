import Foundation

enum UpstreamHistoryText: Codable, Equatable {
    case text(String)
    case tooLarge
}

enum UpstreamHistoryFileContent: Codable, Equatable {
    case text(String)
    case binary
    case tooLarge

    static func utf8PreservingBOM(_ data: Data) -> String? {
        // Foundation validates UTF-8 but drops its leading BOM, so restore that scalar when present.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return data.starts(with: [0xef, 0xbb, 0xbf]) ? "\u{feff}" + text : text
    }
}

struct UpstreamHistoryBaselineFile: Codable, Equatable {
    let path: String
    let content: UpstreamHistoryFileContent
    let fingerprint: String
    let isExecutable: Bool
}

enum UpstreamHistoryBaseline: Codable, Equatable {
    case files([UpstreamHistoryBaselineFile])
    case tooLarge

    var files: [UpstreamHistoryBaselineFile]? {
        guard case let .files(files) = self else { return nil }
        return files
    }
}

struct UpstreamHistoryRow: Codable, Equatable {
    let sha: String
    let author: String
    let date: Date
    let subject: String
    let filesChanged: Int
    let linesAdded: Int?
    let linesRemoved: Int?
    let skillMarkdown: UpstreamHistoryText?
}

enum UpstreamHistoryInstalledPosition: Codable, Equatable {
    case at(sha: String)
    case olderThanRowsRead
    case notInRefHistory
}

struct UpstreamHistoryLocalChange: Equatable {
    let path: String
    let linesAdded: Int?
    let linesRemoved: Int?
    let installedText: String?
    let currentText: String?
}

enum UpstreamHistoryLocalEdits: Equatable {
    case none
    case changed([UpstreamHistoryLocalChange])
    case countsUnknown
}

struct UpstreamHistoryResult: Equatable {
    let headCommit: String
    let rows: [UpstreamHistoryRow]
    let installedPosition: UpstreamHistoryInstalledPosition
    let hasOlderHistory: Bool
    let installedBaseline: UpstreamHistoryBaseline?
    let localEdits: UpstreamHistoryLocalEdits
    let windowCount: Int
}

enum UpstreamHistoryError: LocalizedError, Equatable {
    case unsupportedRepositoryRemote
    case invalidInstalledCommit
    case invalidRef
    case invalidPath
    case invalidWindow
    case trackedRefNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRepositoryRemote:
            "stored repository is not a supported GitHub URL"
        case .invalidInstalledCommit:
            "stored installed commit is not a full object ID"
        case .invalidRef:
            "stored repository ref is unsafe"
        case .invalidPath:
            "stored repository path is unsafe"
        case .invalidWindow:
            "history window must be positive"
        case let .trackedRefNotFound(ref):
            UpdateCheckError.trackedRefNotFound(ref).localizedDescription
        }
    }
}

struct UpstreamHistoryGitRow {
    let sha: String
    let author: String
    let date: Date
    let subject: String
    let filesChanged: Int
    let linesAdded: Int?
    let linesRemoved: Int?
    let skillMarkdown: UpstreamHistoryText?
}

enum UpstreamHistoryGitInstalledPosition {
    case reachable(pathCommit: String?)
    case olderThanScan
    case notInRefHistory
}

struct UpstreamHistoryGitSnapshot {
    let headCommit: String
    let rows: [UpstreamHistoryGitRow]
    let installedPosition: UpstreamHistoryGitInstalledPosition
    let hasMoreCommits: Bool
    let installedBaseline: UpstreamHistoryBaseline?
}

struct UpstreamHistoryGitRequest {
    let remote: String
    let ref: String
    let installedCommit: String
    let path: String
    let repositoryPath: String
    let commitLimit: Int
    let rowLimit: Int
    let textByteLimit: Int
    let baselineFileLimit: Int
    let baselineByteLimit: Int
    let credential: GitCredential?
}

protocol UpstreamHistoryGitServing {
    func upstreamHistory(_ request: UpstreamHistoryGitRequest) throws -> UpstreamHistoryGitSnapshot
    func remoteHead(remote: String, ref: String, credential: GitCredential?) throws -> String?
}

extension GitService: UpstreamHistoryGitServing {}

struct UpstreamHistoryService {
    static let defaultScratchRoot = PathConstants.pensieveAppSupportDir + "/upstream-history-scratch"
    static let commitWindow = 200
    static let rowWindow = 20
    static let textByteLimit = 256 * 1_024
    static let baselineFileLimit = 512
    static let baselineByteLimit = 8 * 1_024 * 1_024
    static let authorLimit = 120
    static let subjectLimit = 300

    let gitService: UpstreamHistoryGitServing
    let credentialStore: CredentialStoreProtocol
    let fileService: FileServiceProtocol
    let contentHasher: SkillContentHashing
    let scratchRoot: String
    let validateRemote: InstallRemotePolicy.Validator
    let requestedCommitWindow: Int
    let requestedRowWindow: Int
    let requestedTextByteLimit: Int
    let requestedBaselineFileLimit: Int
    let requestedBaselineByteLimit: Int

    init(
        gitService: UpstreamHistoryGitServing = GitService(),
        credentialStore: CredentialStoreProtocol = KeychainCredentialStore(),
        fileService: FileServiceProtocol = FileService(),
        contentHasher: SkillContentHashing,
        scratchRoot: String = Self.defaultScratchRoot,
        commitWindow: Int = Self.commitWindow,
        rowWindow: Int = Self.rowWindow,
        textByteLimit: Int = Self.textByteLimit,
        baselineFileLimit: Int = Self.baselineFileLimit,
        baselineByteLimit: Int = Self.baselineByteLimit,
        remoteValidator: @escaping InstallRemotePolicy.Validator =
            InstallRemotePolicy.validateGitHubRepository
    ) {
        self.gitService = gitService
        self.credentialStore = credentialStore
        self.fileService = fileService
        self.contentHasher = contentHasher
        self.scratchRoot = scratchRoot
        self.validateRemote = remoteValidator
        self.requestedCommitWindow = commitWindow
        self.requestedRowWindow = rowWindow
        self.requestedTextByteLimit = textByteLimit
        self.requestedBaselineFileLimit = baselineFileLimit
        self.requestedBaselineByteLimit = baselineByteLimit
    }

    func read(origin: InstalledOrigin, localDirectory: String,
              windowCount: Int = 1) throws -> UpstreamHistoryResult {
        let remote = try validatedRemoteAndCoordinates(origin: origin, windowCount: windowCount)
        let commitLimit = try multipliedWindow(requestedCommitWindow, by: windowCount)
        let visibleCount = try multipliedWindow(requestedRowWindow, by: windowCount)
        let (rowLimit, rowLimitOverflow) = visibleCount.addingReportingOverflow(1)
        guard !rowLimitOverflow else { throw UpstreamHistoryError.invalidWindow }
        try prepareScratchRoot()
        let sessionRoot = scratchRoot + "/" + UUID().uuidString
        try fileService.createDirectory(at: sessionRoot)
        defer { try? fileService.deleteDirectory(at: sessionRoot) }

        let snapshot: UpstreamHistoryGitSnapshot
        do {
            snapshot = try gitService.upstreamHistory(UpstreamHistoryGitRequest(
                remote: remote.cloneRemote,
                ref: origin.ref,
                installedCommit: origin.installedCommit,
                path: origin.path,
                repositoryPath: sessionRoot + "/repository",
                commitLimit: commitLimit,
                rowLimit: rowLimit,
                textByteLimit: requestedTextByteLimit,
                baselineFileLimit: requestedBaselineFileLimit,
                baselineByteLimit: requestedBaselineByteLimit,
                credential: credentialStore.credential(forHost: CredentialHost.githubInstall)
            ))
        } catch {
            throw SkillInstallService.mappedRepositoryError(error)
        }

        let rows = snapshot.rows.prefix(visibleCount).map(Self.safeRow)
        let position = Self.installedPosition(
            snapshot.installedPosition,
            visibleRows: rows
        )
        let baseline: UpstreamHistoryBaseline? = position == .notInRefHistory
            ? nil
            : snapshot.installedBaseline
        let edits = try localEdits(
            localDirectory: localDirectory,
            installedContentHash: origin.contentHash,
            baseline: baseline
        )
        return UpstreamHistoryResult(
            headCommit: snapshot.headCommit,
            rows: Array(rows),
            installedPosition: position,
            hasOlderHistory: snapshot.rows.count > visibleCount || snapshot.hasMoreCommits,
            installedBaseline: baseline,
            localEdits: edits,
            windowCount: windowCount
        )
    }

    func probeHead(origin: InstalledOrigin) throws -> String {
        let remote = try validatedRemoteAndCoordinates(origin: origin, windowCount: 1)
        do {
            guard let head = try gitService.remoteHead(
                remote: remote.cloneRemote,
                ref: origin.ref,
                credential: credentialStore.credential(forHost: CredentialHost.githubInstall)
            ) else {
                throw UpstreamHistoryError.trackedRefNotFound(origin.ref)
            }
            return head
        } catch {
            throw SkillInstallService.mappedRepositoryError(error)
        }
    }

    static func cleanupScratchRoot(
        fileService: FileServiceProtocol = FileService(),
        scratchRoot: String = Self.defaultScratchRoot
    ) {
        if fileService.directoryExists(at: scratchRoot) || fileService.isSymlink(at: scratchRoot) {
            try? fileService.deleteDirectory(at: scratchRoot)
        } else if fileService.fileExists(at: scratchRoot) {
            try? fileService.deleteFile(at: scratchRoot)
        }
    }
}

extension UpstreamHistoryService {
    func validatedRemoteAndCoordinates(origin: InstalledOrigin, windowCount: Int) throws
        -> ValidatedInstallRemote {
        guard windowCount > 0 else { throw UpstreamHistoryError.invalidWindow }
        guard Self.isFullObjectID(origin.installedCommit) else {
            throw UpstreamHistoryError.invalidInstalledCommit
        }
        guard Self.isSafeRef(origin.ref) else { throw UpstreamHistoryError.invalidRef }
        guard Self.isSafePath(origin.path) else { throw UpstreamHistoryError.invalidPath }
        guard let remote = validateRemote(origin.repo) else {
            throw UpstreamHistoryError.unsupportedRepositoryRemote
        }
        return remote
    }

    private func multipliedWindow(_ size: Int, by windowCount: Int) throws -> Int {
        let (value, overflow) = size.multipliedReportingOverflow(by: windowCount)
        guard !overflow else { throw UpstreamHistoryError.invalidWindow }
        return value
    }

    func prepareScratchRoot() throws {
        if fileService.isSymlink(at: scratchRoot) {
            try fileService.deleteDirectory(at: scratchRoot)
        } else if fileService.fileExists(at: scratchRoot) {
            try fileService.deleteFile(at: scratchRoot)
        }
        if !fileService.directoryExists(at: scratchRoot) {
            try fileService.createDirectory(at: scratchRoot)
        }
    }

    static func installedPosition(
        _ position: UpstreamHistoryGitInstalledPosition,
        visibleRows: [UpstreamHistoryRow]
    ) -> UpstreamHistoryInstalledPosition {
        switch position {
        case let .reachable(pathCommit):
            guard let pathCommit,
                  visibleRows.contains(where: { $0.sha == pathCommit }) else {
                return .olderThanRowsRead
            }
            return .at(sha: pathCommit)
        case .olderThanScan:
            return .olderThanRowsRead
        case .notInRefHistory:
            return .notInRefHistory
        }
    }

    static func safeRow(_ row: UpstreamHistoryGitRow) -> UpstreamHistoryRow {
        UpstreamHistoryRow(
            sha: row.sha,
            author: safeDisplay(row.author, limit: authorLimit),
            date: row.date,
            subject: safeDisplay(row.subject, limit: subjectLimit),
            filesChanged: row.filesChanged,
            linesAdded: row.linesAdded,
            linesRemoved: row.linesRemoved,
            skillMarkdown: row.skillMarkdown
        )
    }

    static func isFullObjectID(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0)
        }
    }

    static func isSafeRef(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.hasSuffix("."),
              value != "@",
              !value.contains(".."),
              !value.contains("@{"),
              !containsUnsafeControl(value) else { return false }
        let forbidden = ":*?[\\~^ "
        guard !value.unicodeScalars.contains(where: forbidden.unicodeScalars.contains) else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }

    static func isSafePath(_ value: String) -> Bool {
        InstallRelativePathPolicy.isValid(value)
    }

}
