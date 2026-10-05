import Foundation
import SwiftData
import SwiftUI

@Observable
final class PlatformViewModel {
    private let linkService: LinkServiceProtocol
    private let cursorCompiler: CursorCompilerProtocol
    private let fileService: FileServiceProtocol
    let projectReconcilePolicy: ProjectReconcilePolicy
    private let deployStateStore: DeployStateStore
    private let now: () -> Date
    private let persist: (ModelContext) throws -> Void
    /// Installed agents detected once at construction (install state doesn't change mid-session).
    private let installed: [PlatformTarget]

    var error: String?
    /// Incremented after every deploy/remove attempt to refresh status even after a partial failure.
    private(set) var refreshCounter = 0
    /// This Mac's recorded deploys, for list rows and the Skills filter (PLAN-29). Rebuilt from
    /// `deploy-state.json` by `refreshDeployIndex()` after every write this object makes and, through
    /// `AppRuntime`, after the launch backfill and each post-sync convergence; a SwiftUI body reads it
    /// as observable state and never calls `isDeployed` per row.
    private(set) var deployIndex = DeployIndex.empty

    init(
        fileService: FileServiceProtocol? = nil,
        linkService: LinkServiceProtocol? = nil,
        cursorCompiler: CursorCompilerProtocol? = nil,
        agentDetection: AgentDetectionServiceProtocol? = nil,
        deployStateStore: DeployStateStore? = nil,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        let fs = fileService ?? FileService()
        self.fileService = fs
        self.projectReconcilePolicy = ProjectReconcilePolicy(fileService: fs)
        self.linkService = linkService ?? LinkService(fileService: fs)
        self.cursorCompiler = cursorCompiler ?? CursorCompiler(
            fileService: fs,
            skillStore: SkillStore(fileService: fs)
        )
        self.deployStateStore = deployStateStore ?? DeployStateStore(fileService: fs)
        self.now = now
        self.persist = persist
        self.installed = (agentDetection ?? AgentDetectionService()).installedPlatforms()
        refreshDeployIndex()
    }

    // MARK: - Installed agents

    /// The agents actually installed on this machine — the deploy UI iterates only these.
    func installedPlatforms() -> [PlatformTarget] { installed }

    func deployablePlatforms(forProject: Bool) -> [PlatformTarget] {
        forProject ? installed.filter(\.supportsProjectScope) : installed
    }

    // MARK: - Deploy index

    /// Re-read `deploy-state.json` into `deployIndex`. A refused read (unreadable bytes, newer schema)
    /// publishes `.unavailable`, never an empty index that would read as "nothing deployed".
    func refreshDeployIndex() {
        do {
            deployIndex = DeployIndex(records: try deployStateStore.read().records)
        } catch {
            deployIndex = .unavailable
        }
    }

    /// The one place a change to what is deployed is announced: the status counter that re-keys the
    /// detail snapshot (the Platforms panel re-reads the filesystem), then the index the lists read.
    /// Called after every write this object makes, and by `AppRuntime` after each post-sync convergence,
    /// whose `DeployReconciler` can prune links and recompile Cursor rules without this object's help.
    func noteDeployStateChanged() {
        refreshCounter += 1
        refreshDeployIndex()
    }

    // MARK: - Status

    func isDeployed(skill: Skill, platform: PlatformTarget, target: DeployTarget = .userWide) -> Bool {
        let projectPath = target.project?.path
        if platform.usesSymlinks {
            return linkService.isLinked(skill: skill, platform: platform, projectPath: projectPath)
        } else {
            return cursorCompiler.isUpToDate(skill: skill, projectPath: projectPath)
        }
    }

    func artifactExists(skill: Skill, platform: PlatformTarget, target: DeployTarget = .userWide) -> Bool {
        guard ProjectDirectory.canAccess(target.project?.path) else { return false }
        let path = artifactPath(skill: skill, platform: platform, target: target)
        guard !path.isEmpty else { return false }
        return (platform.usesSymlinks && fileService.isSymlink(at: path)) || fileService.fileExists(at: path)
    }

    // MARK: - Throwing core (one pair)

    /// Deploy a single (skill, platform) pair, throwing on any failure. The single-deploy wrapper
    /// and the batch path both call this so failure handling lives in one place (PLAN-04 04.5).
    @discardableResult
    private func deployOne(
        skill: Skill,
        platform: PlatformTarget,
        target: DeployTarget,
        context: ModelContext
    ) throws -> DeployOutcome {
        // C7: refuse to deploy through an unsafe canonical slug dir - a symlinked, traversing, or
        // realpath-escaping dir would link/compile/hash from attacker-redirected content. Guard at
        // the TOP so LinkService / CursorCompiler are never reached for an unsafe dir. Single shared
        // C7 resolver (PLAN-11) - levels this site up to component validation.
        guard SkillStore.safeSkillDirectory(
                slug: skill.directoryName, base: Constants.pensieveSkillsDir, fileService: fileService) != nil else {
            throw SkillStoreError.invalidDirectory(skill.directoryName)
        }
        // Leaf guard: a symlink-platform deploy never reaches CursorCompiler's
        // readBody, and the contentsHash below reads the leaf directly — so deploy refuses a
        // non-regular SKILL.md leaf here, before any link/compile/hash.
        guard let safeSkillPath = SkillStore.safeSkillFile(
                slug: skill.directoryName, base: Constants.pensieveSkillsDir, fileService: fileService) else {
            throw SkillStoreError.unsafeLeaf(skill.directoryName)
        }

        let projectPath = target.project?.path
        if platform.usesSymlinks {
            try linkService.link(skill: skill, platform: platform, projectPath: projectPath)
        } else {
            try cursorCompiler.compile(skill: skill, projectPath: projectPath)
        }

        let targetPath = platform.usesSymlinks
            ? linkService.linkPath(skill: skill, platform: platform, projectPath: projectPath)
            : cursorCompiler.outputPath(skill: skill, projectPath: projectPath)

        let hash = (try? fileService.contentsHash(at: safeSkillPath)) ?? ""
        let record = DeployRecord(
            skillID: skill.id,
            platform: platform,
            targetPath: targetPath,
            contentHash: hash,
            projectID: target.project?.id
        )
        context.insert(record)
        try persist(context)
        recordDeployState(
            skill: skill,
            platform: platform,
            target: target,
            artifactPath: targetPath
        )
        return DeployOutcome(targetPath: targetPath)
    }

    /// Remove a single (skill, platform) pair, throwing on failure. Mirrors the existing
    /// `remove` behavior (no DeployRecord deletion — unchanged from before this stage).
    private func removeOne(skill: Skill, platform: PlatformTarget, target: DeployTarget) throws {
        let path = artifactPath(skill: skill, platform: platform, target: target)
        try removeArtifact(skill: skill, platform: platform, target: target)
        do {
            try deployStateStore.remove(artifactPath: path)
        } catch {
            NSLog("Pensieve deploy-state remove failed for \(path): \(error)")
        }
    }

    private func removeArtifact(skill: Skill, platform: PlatformTarget, target: DeployTarget) throws {
        let projectPath = target.project?.path
        if platform.usesSymlinks {
            try linkService.unlink(skill: skill, platform: platform, projectPath: projectPath)
        } else {
            try cursorCompiler.remove(skill: skill, projectPath: projectPath)
        }
    }

    private func artifactPath(skill: Skill, platform: PlatformTarget, target: DeployTarget) -> String {
        let projectPath = target.project?.path
        return platform.usesSymlinks
            ? linkService.linkPath(skill: skill, platform: platform, projectPath: projectPath)
            : cursorCompiler.outputPath(skill: skill, projectPath: projectPath)
    }

    private func recordDeployState(
        skill: Skill,
        platform: PlatformTarget,
        target: DeployTarget,
        artifactPath: String
    ) {
        let scope: String
        let projectIdentityKey: String?
        if let project = target.project {
            guard let identityKey = project.identityKey else {
                NSLog("Pensieve deploy-state skipped project record for \(artifactPath): missing project identityKey")
                return
            }
            scope = "project"
            projectIdentityKey = identityKey
        } else {
            scope = "user"
            projectIdentityKey = nil
        }

        let record = DeployStateRecord(
            slug: skill.directoryName,
            platform: platform.rawValue,
            scope: scope,
            projectIdentityKey: projectIdentityKey,
            artifactPath: artifactPath,
            recordedAt: Self.recordedAtFormatter.string(from: now())
        )
        do {
            try deployStateStore.upsert(record)
        } catch {
            NSLog("Pensieve deploy-state upsert failed for \(artifactPath): \(error)")
        }
    }

    private static let recordedAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Deploy / Remove (single — UI behavior unchanged)

    func deploy(skill: Skill, platform: PlatformTarget, target: DeployTarget = .userWide, context: ModelContext) {
        defer { noteDeployStateChanged() }
        do {
            _ = try deployOne(skill: skill, platform: platform, target: target, context: context)
            error = nil
        } catch {
            self.error = "Deploy failed: \(BatchPairOutcome.failureMessage(error, target: target))"
        }
    }

    func remove(skill: Skill, platform: PlatformTarget, target: DeployTarget = .userWide) {
        defer { noteDeployStateChanged() }
        do {
            try removeOne(skill: skill, platform: platform, target: target)
            error = nil
        } catch {
            self.error = "Remove failed: \(error.localizedDescription)"
        }
    }

    /// Toggle a single (skill, platform, target): remove when currently deployed, deploy otherwise.
    /// The status read happens here, in an action, never in a view body.
    func toggleDeploy(skill: Skill, platform: PlatformTarget, target: DeployTarget, context: ModelContext) {
        if isDeployed(skill: skill, platform: platform, target: target) {
            remove(skill: skill, platform: platform, target: target)
        } else {
            deploy(skill: skill, platform: platform, target: target, context: context)
        }
    }

    // MARK: - Bulk deploy / remove (resilient — one bad pair never aborts the rest)

    /// Deploy every (skill × platform) pair, collecting a per-pair outcome. A thrown error on one
    /// pair is caught and recorded, never rethrown (ROADMAP §GOOD-2 "keep going when a single item
    /// fails"). One `DeployRecord` per successful pair, as in single deploy.
    func deployBatch(
        skills: [Skill],
        platforms: [PlatformTarget],
        target: DeployTarget = .userWide,
        context: ModelContext
    ) -> BatchResult {
        var result = BatchResult()
        for skill in skills {
            for platform in platforms {
                do {
                    _ = try deployOne(skill: skill, platform: platform, target: target, context: context)
                    result.outcomes.append(BatchPairOutcome(
                        skillID: skill.id, skillName: skill.name, platform: platform,
                        target: BatchPairTarget(target), error: nil
                    ))
                } catch {
                    result.outcomes.append(BatchPairOutcome(
                        skillID: skill.id, skillName: skill.name, platform: platform,
                        target: BatchPairTarget(target), error: BatchPairOutcome.failureMessage(error, target: target),
                        projectFolderError: error as? ProjectFolderError
                    ))
                }
            }
        }
        noteDeployStateChanged()
        return result
    }

    /// Remove every (skill × platform) pair, resilient to a single failing pair. Mirrors `removeOne`.
    func removeBatch(
        skills: [Skill],
        platforms: [PlatformTarget],
        target: DeployTarget = .userWide
    ) -> BatchResult {
        var result = BatchResult()
        for skill in skills {
            for platform in platforms {
                do {
                    try removeOne(skill: skill, platform: platform, target: target)
                    result.outcomes.append(BatchPairOutcome(
                        skillID: skill.id, skillName: skill.name, platform: platform,
                        target: BatchPairTarget(target), error: nil
                    ))
                } catch {
                    result.outcomes.append(BatchPairOutcome(
                        skillID: skill.id, skillName: skill.name, platform: platform,
                        target: BatchPairTarget(target), error: BatchPairOutcome.failureMessage(error, target: target),
                        projectFolderError: error as? ProjectFolderError
                    ))
                }
            }
        }
        noteDeployStateChanged()
        return result
    }

    // MARK: - Validation

    func brokenLinks(skills: [Skill]) -> [BrokenLink] {
        linkService.validateAll(skills: skills)
    }
}

extension PlatformViewModel {
    /// Remove every symlink Pensieve made for this skill on the platforms detected at launch,
    /// user-wide and in every given project, and drop each one's deploy-state record exactly once —
    /// per-pair outcomes. A symlink is ours only when isLinked (it points at Pensieve's target).
    /// Cursor files are never touched here (no durable ownership signal). A symlink-platform
    /// record with nothing of ours at its path is just dropped. Deploy state is read once, up front;
    /// a refused read (corrupt bytes or a newer schema) touches nothing that exists.
    func removeAllDeploys(skill: Skill, projects: [Project]) -> BatchResult {
        var result = BatchResult()
        let targets: [DeployTarget] = [.userWide] + projects.map { .project($0) }
        let recorded: Set<String>?     // the one read; nil = the store refused it (stateProblem says why)
        let stateProblem: String
        do {
            recorded = try deployStateStore.recordedArtifactPaths()
            stateProblem = ""
        } catch DeployStateError.unsupportedSchema(let version) {
            recorded = nil
            stateProblem = "deploy state uses a newer schema (\(version)); update Pensieve"
        } catch {
            recorded = nil
            stateProblem = "deploy state unreadable"
        }
        for target in targets {
            for platform in deployablePlatforms(forProject: target.project != nil) where platform.usesSymlinks {
                let path = artifactPath(skill: skill, platform: platform, target: target)
                // `isDeployed` is `isLinked` here: symlink AND target == ours.
                let ours = isDeployed(skill: skill, platform: platform, target: target)
                guard let recorded else {
                    if ours {
                        result.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: platform,
                                                                target: BatchPairTarget(target),
                                                                error: "\(stateProblem); nothing removed at \(path)"))
                    }
                    continue
                }
                guard ours || recorded.contains(path) else { continue }
                do {
                    if ours { try removeArtifact(skill: skill, platform: platform, target: target) }
                    try deployStateStore.remove(artifactPath: path)   // the one state write for this pair
                    result.outcomes.append(BatchPairOutcome(
                        skillID: skill.id, skillName: skill.name, platform: platform,
                        target: BatchPairTarget(target), error: nil
                    ))
                } catch {
                    result.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: platform,
                                                            target: BatchPairTarget(target),
                                                            error: error.localizedDescription))
                }
            }
        }
        if !result.outcomes.isEmpty { noteDeployStateChanged() }
        return result
    }

}

extension PlatformViewModel {
    /// Classifies user-wide legacy ownership before convergence. LinkService supplies the same
    /// literal-target judgment used by broken-link validation; every regular Cursor file stays owned.
    func scenarioHandoverDeployState(skill: Skill, platform: PlatformTarget) throws -> ScenarioHandoverDeployState {
        let path = platform.usesSymlinks
            ? linkService.linkPath(skill: skill, platform: platform, projectPath: nil)
            : cursorCompiler.outputPath(skill: skill, projectPath: nil)
        guard let type = try fileService.entryTypeWithoutFollowingLinks(at: path) else { return .absent }
        if platform.usesSymlinks {
            guard type == .symlink else { return .unmanaged }
            let actual = try fileService.symlinkTarget(at: path)
            let expected = linkService.targetPath(skill: skill, platform: platform, projectPath: nil)
            return actual == expected ? .realized : .unmanaged
        }
        return type == .regular ? .realized : .unmanaged
    }
}
