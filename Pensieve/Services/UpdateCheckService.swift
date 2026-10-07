import Foundation
import SwiftData

enum UpdateCheckFrequency: String, CaseIterable, Identifiable {
    case off
    case daily
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }
}

enum UpdateCheckSchedule {
    static let frequencyKey = "updateCheckFrequency"
    static let lastAutoCheckAtKey = "lastAutoCheckAt"

    static func isDue(frequency: UpdateCheckFrequency,
                      lastAutoCheckAt: Date?, now: Date) -> Bool {
        let interval: TimeInterval
        switch frequency {
        case .off:
            return false
        case .daily:
            interval = 24 * 60 * 60
        case .weekly:
            interval = 7 * 24 * 60 * 60
        }
        guard let lastAutoCheckAt else { return true }
        return now.timeIntervalSince(lastAutoCheckAt) >= interval
    }
}

protocol UpdateCheckGitServing {
    func probeUsability() throws -> GitUsability
    func remoteHead(remote: String, ref: String,
                    credential: GitCredential?) throws -> String?
    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?) throws
    func commitSHA(at path: String) throws -> String
    func commitDate(at repositoryPath: String) throws -> Date
    func treeHash(at repositoryPath: String, path: String) throws -> String
}

extension UpdateCheckGitServing {
    func probeUsability() -> GitUsability { .usable }
}

extension GitService: UpdateCheckGitServing {}

protocol SkillContentHashing {
    func stableContentHash(at directory: String,
                           excludingTopLevelGitMetadata: Bool) throws -> String
}

extension SkillInstallService: SkillContentHashing {}

enum UpdateCheckError: LocalizedError, Equatable {
    case unsupportedRepositoryRemote
    case trackedRefNotFound(String)
    case repositoryMovedDuringCheck
    case unsafeSkillDirectory(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRepositoryRemote:
            "Stored repository is not a supported GitHub URL."
        case let .trackedRefNotFound(ref):
            "Tracked branch or tag '\(ref)' was not found."
        case .repositoryMovedDuringCheck:
            "Repository changed during the check — check again."
        case let .unsafeSkillDirectory(slug):
            "The local skill directory is unsafe: \(slug)"
        }
    }
}

struct UpdateCheckService {
    static let defaultScratchRoot = PathConstants.pensieveAppSupportDir + "/update-check-scratch"

    struct Snapshot {
        let id: UUID
        let directoryName: String
        let origin: InstalledOrigin
        let lastCheckedHead: String?
    }

    struct BatchKey: Hashable {
        let repo: String
        let cloneRemote: String
        let ref: String
    }

    let gitService: UpdateCheckGitServing
    let credentialStore: CredentialStoreProtocol
    let fileService: FileServiceProtocol
    let contentHasher: SkillContentHashing
    let scratchRoot: String
    let storeRoot: String
    let now: () -> Date
    let validateRemote: InstallRemotePolicy.Validator

    init(gitService: UpdateCheckGitServing = GitService(),
         credentialStore: CredentialStoreProtocol = KeychainCredentialStore(),
         fileService: FileServiceProtocol = FileService(),
         contentHasher: SkillContentHashing? = nil,
         scratchRoot: String = Self.defaultScratchRoot,
         storeRoot: String = Constants.pensieveBaseDir,
         now: @escaping () -> Date = Date.init,
         remoteValidator: @escaping InstallRemotePolicy.Validator =
             InstallRemotePolicy.validateGitHubRepository) {
        self.gitService = gitService
        self.credentialStore = credentialStore
        self.fileService = fileService
        self.contentHasher = contentHasher ?? SkillInstallService(
            credentialStore: credentialStore,
            fileService: fileService,
            storeRoot: storeRoot,
            remoteValidator: remoteValidator
        )
        self.scratchRoot = scratchRoot
        self.storeRoot = storeRoot
        self.now = now
        self.validateRemote = remoteValidator
    }

    @discardableResult
    func checkAll(context: ModelContext) throws -> UpdateCheckReport {
        try check(skillIDs: nil, context: context)
    }

    func check(skillID: UUID, context: ModelContext) throws {
        let report = try check(skillIDs: Set([skillID]), context: context)
        if let failure = report.environmentError { throw failure }
    }

    func driftedLocally(skill: Skill) throws -> Bool {
        guard skill.hasLinkedOrigin, let origin = skill.installedOrigin else { return false }
        guard let directory = SkillStore.safeSkillDirectory(
            slug: skill.directoryName,
            base: storeRoot + "/skills",
            fileService: fileService
        ), fileService.directoryExists(at: directory) else {
            throw UpdateCheckError.unsafeSkillDirectory(skill.directoryName)
        }
        guard SkillStore.safeSkillFile(
            slug: skill.directoryName,
            base: storeRoot + "/skills",
            fileService: fileService
        ) != nil else {
            throw UpdateCheckError.unsafeSkillDirectory(skill.directoryName)
        }
        let currentHash = try contentHasher.stableContentHash(
            at: directory,
            excludingTopLevelGitMetadata: false
        )
        return Self.driftedLocally(
            currentContentHash: currentHash,
            installedContentHash: origin.contentHash
        )
    }

    static func driftedLocally(currentContentHash: String,
                               installedContentHash: String) -> Bool {
        currentContentHash != installedContentHash
    }

    static func cleanupScratchRoot(fileService: FileServiceProtocol = FileService(),
                                   scratchRoot: String = Self.defaultScratchRoot) {
        if fileService.directoryExists(at: scratchRoot) || fileService.isSymlink(at: scratchRoot) {
            try? fileService.deleteDirectory(at: scratchRoot)
        } else if fileService.fileExists(at: scratchRoot) {
            try? fileService.deleteFile(at: scratchRoot)
        }
    }
}

extension UpdateCheckService {
    private func check(skillIDs: Set<UUID>?, context: ModelContext) throws -> UpdateCheckReport {
        var report = UpdateCheckReport()
        let skills = try context.fetch(FetchDescriptor<Skill>()).filter {
            skillIDs?.contains($0.id) ?? true
        }
        var batches: [BatchKey: [Snapshot]] = [:]
        for skill in skills {
            guard skill.hasLinkedOrigin, let origin = skill.installedOrigin else { continue }
            guard let remote = validateRemote(origin.repo) else {
                try writeError(
                    UpdateCheckError.unsupportedRepositoryRemote.localizedDescription,
                    snapshot: makeSnapshot(skill: skill, origin: origin),
                    context: context
                )
                continue
            }
            let snapshot = makeSnapshot(skill: skill, origin: origin)
            let key = BatchKey(repo: remote.repo, cloneRemote: remote.cloneRemote, ref: origin.ref)
            batches[key, default: []].append(snapshot)
        }

        guard !batches.isEmpty else { return report }
        do {
            let usability = try gitService.probeUsability()
            report.gitUsability = usability
            guard usability == .usable else {
                report.environmentError = GitError.unusable(usability)
                return report
            }
            for key in batches.keys.sorted(by: batchOrder) {
                if let snapshots = batches[key] {
                    try checkBatch(key: key, snapshots: snapshots, context: context, report: &report)
                }
            }
        } catch {
            throw UpdateCheckExecutionFailure(report: report, underlying: error)
        }
        return report
    }

    private func checkBatch(key: BatchKey, snapshots: [Snapshot], context: ModelContext,
                            report: inout UpdateCheckReport) throws {
        let diagnostics = UpdateBatchDiagnostics(probe: gitService.probeUsability)
        defer { if let evidence = diagnostics.evidence { report.gitUsability = evidence } }
        let checkedAt = now()
        let credential = credentialStore.credential(forHost: CredentialHost.githubInstall)
        let head: String
        do {
            let resolved = try gitService.remoteHead(
                remote: key.cloneRemote,
                ref: key.ref,
                credential: credential
            )
            report.reachedRemote = true
            diagnostics.recordUsable()
            guard let resolved else { throw UpdateCheckError.trackedRefNotFound(key.ref) }
            head = resolved
        } catch {
            let failure = diagnostics.classify(error)
            if failure.environment {
                if report.environmentError == nil { report.environmentError = failure.error }
            } else {
                try writeError(errorMessage(failure.error), snapshots: snapshots, context: context)
            }
            return
        }

        let pending = snapshots.filter { $0.lastCheckedHead != head }
        // Finish all source-wide network work before changing even the already-current skills.
        if !pending.isEmpty {
            do {
                let (commitDate, trees) = try readMovedHead(key: key, head: head, snapshots: pending,
                                                          credential: credential, diagnostics: diagnostics)
                try evaluateSkills(trees, head: head, commitDate: commitDate, checkedAt: checkedAt, context: context)
            } catch {
                let failure = diagnostics.classify(error)
                if failure.environment {
                    if report.environmentError == nil { report.environmentError = failure.error }
                    return
                }
                try writeError(errorMessage(failure.error), snapshots: pending, context: context)
            }
        }
        try updateCursor(key: key, head: head, checkedAt: checkedAt, context: context)
        for snapshot in snapshots where snapshot.lastCheckedHead == head {
            try writeUnmoved(snapshot: snapshot, checkedAt: checkedAt, context: context)
        }
    }

    private func readMovedHead(key: BatchKey, head: String, snapshots: [Snapshot], credential: GitCredential?,
                               diagnostics: UpdateBatchDiagnostics) throws -> (Date, [(Snapshot, Result<String, Error>)]) {
        try prepareScratchRoot()
        let sessionRoot = scratchRoot + "/" + UUID().uuidString
        try fileService.createDirectory(at: sessionRoot)
        defer { try? fileService.deleteDirectory(at: sessionRoot) }
        let checkout = sessionRoot + "/repository"
        diagnostics.beginNextGitOperation()
        try gitService.cloneShallow(remote: key.cloneRemote, branch: key.ref,
                                    into: checkout, credential: credential)
        guard try gitService.commitSHA(at: checkout) == head else {
            throw UpdateCheckError.repositoryMovedDuringCheck
        }
        let commitDate = try gitService.commitDate(at: checkout)
        // Read the whole batch before persisting: a host failure on a later tree preserves earlier skills too.
        let trees = try snapshots.map { snapshot -> (Snapshot, Result<String, Error>) in
            var tree = Result { try gitService.treeHash(at: checkout, path: snapshot.origin.path) }
            if case let .failure(error) = tree {
                let failure = diagnostics.classify(error)
                if failure.environment { throw failure.error }
                tree = .failure(failure.error)
            }
            return (snapshot, tree)
        }
        return (commitDate, trees)
    }

}
