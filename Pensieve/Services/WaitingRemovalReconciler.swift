import Foundation
import SwiftData

protocol WaitingRemovalReconciling {
    func reconcile(context: ModelContext) -> BatchResult
}

/// Read all desired project work before executing any waiting removal. Requests arbitrate by
/// the artifact entry's path, resolving its parent but never following the occupant itself.
struct WaitingRemovalReconciler: WaitingRemovalReconciling {
    let store: WaitingRemovalStoring
    let fileService: FileServiceProtocol
    let platformVM: PlatformViewModel
    let machineIdentity: MachineIdentityProviding
    var stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher()

    func reconcile(context: ModelContext) -> BatchResult {
        let waiting: [WaitingRemoval]
        let reachable: [WaitingRemoval]
        let desired: Set<String>
        let folders = ProjectFolderProbe(fileService: fileService)
        do {
            waiting = try store.read()
            guard !waiting.isEmpty else { return BatchResult() }
            reachable = reachableEntries(waiting, folders: folders)
            guard !reachable.isEmpty else { return BatchResult() }
            desired = try desiredPaths(context: context, machineID: machineIdentity.identifier(), folders: folders)
        } catch { return BatchResult.readFailure("waiting removals", error: error) }

        var retire: Set<UUID> = []
        var result = BatchResult()
        var work: [(entry: WaitingRemoval, candidate: DeployRemovalCandidate)] = []
        for entry in reachable {
            let path: String
            do {
                path = try entryPath(entry.artifactPath)
            } catch {
                result.operationFailures.append("\(entry.artifactPath): \(error.localizedDescription)")
                continue
            }
            if desired.contains(path) {
                retire.insert(entry.id)
            } else {
                let key = DeployRemovalKey(slug: entry.slug, platform: entry.platform,
                    projectPath: entry.projectPath, artifactPath: entry.artifactPath)
                let operation = DeployRemovalOperation(fileService: fileService, path: entry.artifactPath) {
                    try occupant(entry)
                }
                work.append((entry, DeployRemovalCandidate(key: key, evidence: [.localProjectRecords], operation: operation)))
            }
        }
        let removal = platformVM.removalService.remove(work.map(\.candidate))
        result.append(finish(removal, entries: work.map(\.entry), retiring: retire))
        return result
    }

    private func finish(_ removal: DeployRemovalResult, entries: [WaitingRemoval], retiring: Set<UUID>) -> BatchResult {
        var retire = retiring
        var result = BatchResult()
        // Admission can precede classification by seconds. Only uncertain completions need
        // this fresh phase, after every occupant was judged; share its answer within a folder.
        let finalFolders = ProjectFolderProbe(fileService: fileService)
        for (entry, outcome) in zip(entries, removal.outcomes) {
            if outcome.foundAbsent || outcome.failure != nil,
               !finalFolders.isAvailable(entry.projectPath) { continue }
            if let error = outcome.failure ?? (outcome.completed ? removal.stateWriteFailure : nil) {
                result.operationFailures.append("\(entry.artifactPath): \(error.localizedDescription)")
            } else if outcome.completed { retire.insert(entry.id) }
        }
        do { try store.retire(ids: retire) } catch {
            result.operationFailures.append(error.localizedDescription)
        }
        result.didRemoveArtifacts = removal.didRemoveArtifacts
        if removal.didRemoveArtifacts || removal.didChangeRecords { platformVM.noteDeployStateChanged() }
        return result
    }

    private func reachableEntries(_ waiting: [WaitingRemoval], folders: ProjectFolderProbe) -> [WaitingRemoval] {
        return waiting.filter { entry in
            folders.isAvailable(entry.projectPath)
        }
    }

    private func desiredPaths(context: ModelContext, machineID: String,
                              folders: ProjectFolderProbe) throws -> Set<String> {
        let projects = try stateFetcher.projects(context: context)
        let skills = try stateFetcher.skills(context: context)
        let intents = try stateFetcher.deployIntents(context: context)
        let categories = try stateFetcher.categories(context: context)
        let deployments = try platformVM.deployStateStore.read().records
        let bySlug = Dictionary(skills.map { ($0.directoryName, $0) }, uniquingKeysWith: { first, _ in first })
        var paths: Set<String> = []
        func request(_ skill: Skill, _ platform: PlatformTarget, _ project: Project) throws {
            let path = platformVM.artifactPath(skill: skill, platform: platform, target: .project(project))
            // An unavailable project's paths remain lexical. Only resolution inside a reachable
            // folder can fail the complete desired-state read.
            paths.insert(folders.isAvailable(project.path) ? try entryPath(path) : path)
        }
        for intent in intents where intent.machineID == machineID {
            guard let key = intent.projectKey, let skill = bySlug[intent.skillSlug],
                  let platform = PlatformTarget(rawValue: intent.platformRaw), platform.supportsProjectScope else { continue }
            for project in projects where project.identityKey == key {
                try request(skill, platform, project)
            }
        }
        for category in categories {
            for project in projects where project.identityKey.map(category.projectKeys.contains) == true {
                for slug in category.skillSlugs {
                    guard let skill = bySlug[slug] else { continue }
                    for platform in platformVM.deployablePlatforms(forProject: true) {
                        try request(skill, platform, project)
                    }
                }
            }
        }
        paths.formUnion(try deployedPaths(deployments, projects: projects, bySlug: bySlug, folders: folders))
        return paths
    }

    private func deployedPaths(_ deployments: [DeployStateRecord], projects: [Project], bySlug: [String: Skill],
                               folders: ProjectFolderProbe) throws -> Set<String> {
        var paths: Set<String> = []
        // Derived deployment state requests live skills in registered projects, including keyless
        // direct deploys. History remains after un-assignment and cannot supply current requests.
        let registered = projects.filter { ProjectDirectory.canAccess($0.path) }
        for record in deployments where record.scope == "project" {
            guard let skill = bySlug[record.slug], let platform = PlatformTarget(rawValue: record.platform),
                  platform.supportsProjectScope else { continue }
            for project in registered where PathSyntax.hasPrefix(record.artifactPath, project.path + "/") {
                let path = platformVM.artifactPath(skill: skill, platform: platform, target: .project(project))
                guard path == record.artifactPath else { continue }
                paths.insert(folders.isAvailable(project.path) ? try entryPath(path) : path)
            }
        }
        return paths
    }

    private func entryPath(_ path: String) throws -> String {
        let entry = path as NSString
        do {
            return try fileService.resolveRealPath(at: entry.deletingLastPathComponent) + "/" + entry.lastPathComponent
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && (error.code == Int(ENOENT) || error.code == Int(ENOTDIR)) {
            // A not-yet-created parent cannot hide a currently occupied requested path.
            return path
        }
    }

    private func occupant(_ entry: WaitingRemoval) throws -> DeployArtifactOccupant {
        let ownership = DeployArtifactOwnership(fileService: fileService)
        if entry.platform.usesSymlinks {
            return try ownership.link(at: entry.artifactPath, skillsDirectory: platformVM.skillsDirectory,
                linksFile: entry.platform == .codex)
        }
        let occupant = try ownership.cursor(at: entry.artifactPath, legacyContent: nil)
        guard occupant == .foreign, let fingerprint = entry.legacyFingerprint,
              try ownership.cursorRuleMayExist(at: entry.artifactPath) else { return occupant }
        do {
            let bytes = try fileService.readRegularFileData(at: entry.artifactPath, maximumBytes: fingerprint.byteCount)
            return bytes.count == fingerprint.byteCount && CursorRemovalFingerprint.digest(bytes) == fingerprint.digest
                ? .legacy : .foreign
        } catch let error as CocoaError where error.code == .fileReadTooLarge { return .foreign }
    }
}
