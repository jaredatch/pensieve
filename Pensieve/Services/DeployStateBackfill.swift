import Foundation
import SwiftData

protocol DeployStateBackfilling {
    func backfill(context: ModelContext)
}

struct DeployStateBackfillPaths {
    var pensieveSkillsDir: String
    var cursorUserRulesDir: String
    var userSkillsRoot: (PlatformTarget) -> String? = DeployPaths.userSkillsRoot(for:)

    static var defaults: DeployStateBackfillPaths {
        DeployStateBackfillPaths(
            pensieveSkillsDir: Constants.pensieveSkillsDir,
            cursorUserRulesDir: Constants.cursorUserRulesDir
        )
    }
}

struct DeployStateBackfill: DeployStateBackfilling {
    private struct Candidate {
        let slug: String
        let platform: PlatformTarget
        let scope: String
        let projectIdentityKey: String?
        let artifactPath: String
    }

    private let fileService: FileServiceProtocol
    private let store: DeployStateStore
    private let paths: DeployStateBackfillPaths
    private let now: () -> Date

    init(
        fileService: FileServiceProtocol = FileService(),
        store: DeployStateStore? = nil,
        paths: DeployStateBackfillPaths = .defaults,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileService = fileService
        self.store = store ?? DeployStateStore(fileService: fileService)
        self.paths = paths
        self.now = now
    }

    func backfill(context: ModelContext) {
        do {
            try replaceDerivedState(context: context)
        } catch {
            NSLog("Pensieve deploy-state backfill failed: \(error)")
        }
    }

    private func replaceDerivedState(context: ModelContext) throws {
        let oldRecords = (try? store.read())?.records ?? []
        var oldRecordedAtByPath: [String: String] = [:]
        for record in oldRecords where oldRecordedAtByPath[record.artifactPath] == nil {
            oldRecordedAtByPath[record.artifactPath] = record.recordedAt
        }
        let stamp = recordedAtFormatter.string(from: now())
        let records = try deriveCandidates(context: context).map { candidate in
            DeployStateRecord(
                slug: candidate.slug,
                platform: candidate.platform.rawValue,
                scope: candidate.scope,
                projectIdentityKey: candidate.projectIdentityKey,
                artifactPath: candidate.artifactPath,
                recordedAt: oldRecordedAtByPath[candidate.artifactPath] ?? stamp
            )
        }
        try store.replaceAll(records)
    }

    private func deriveCandidates(context: ModelContext) throws -> [Candidate] {
        var candidates: [Candidate] = []
        candidates.append(contentsOf: userWideSymlinkCandidates())

        let deployRecords = try context.fetch(FetchDescriptor<DeployRecord>())
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let projects = try context.fetch(FetchDescriptor<Project>())
        let skillsByID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        candidates.append(contentsOf: userWideCursorCandidates(from: deployRecords))
        candidates.append(contentsOf: projectScopedCandidates(
            from: deployRecords,
            skillsByID: skillsByID,
            projectsByID: projectsByID
        ))
        // Collapse to one candidate per artifactPath (the schema's unique key): a project
        // registered at the user's HOME makes project-scoped paths coincide with user-wide ones,
        // and the sources above would each claim the path. Source order IS the precedence —
        // user-wide symlink scan, then user-wide Cursor history, then project history — so the
        // user-wide claim wins deterministically.
        var seenPaths = Set<String>()
        return candidates.filter { seenPaths.insert($0.artifactPath).inserted }
    }

    private func userWideSymlinkCandidates() -> [Candidate] {
        var candidates: [Candidate] = []
        for (dir, platform) in Self.userWideSymlinkDirectories(paths: paths) {
            if fileService.isSymlink(at: dir) || !isRealpathContained(dir) {
                continue
            }
            guard fileService.directoryExists(at: dir),
                  let entries = try? fileService.listDirectory(at: dir) else { continue }
            for entry in entries {
                guard SkillStore.safeSkillDirectory(
                    slug: entry,
                    base: paths.pensieveSkillsDir,
                    fileService: fileService
                ) != nil else { continue }
                let artifactPath = dir + "/" + entry
                let target = paths.pensieveSkillsDir + "/" + entry
                guard fileService.isSymlink(at: artifactPath),
                      (try? fileService.symlinkTarget(at: artifactPath)) == target,
                      fileService.directoryExists(at: target) else { continue }
                candidates.append(Candidate(
                    slug: entry,
                    platform: platform,
                    scope: "user",
                    projectIdentityKey: nil,
                    artifactPath: artifactPath
                ))
            }
        }
        return candidates
    }

    static func userWideSymlinkDirectories(
        paths: DeployStateBackfillPaths
    ) -> [(directory: String, platform: PlatformTarget)] {
        PlatformTarget.allCases.compactMap { platform in
            guard let directory = paths.userSkillsRoot(platform) else { return nil }
            return (directory, platform)
        }
    }

    private func userWideCursorCandidates(from deployRecords: [DeployRecord]) -> [Candidate] {
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for record in deployRecords where record.platform == .cursor && record.projectID == nil {
            guard seen.insert(record.targetPath).inserted,
                  let slug = DeployPaths.slug(artifactPath: record.targetPath, platform: .cursor, projectPath: nil,
                                              cursorUserRulesDirectory: paths.cursorUserRulesDir),
                  fileService.fileExists(at: record.targetPath) else { continue }
            candidates.append(Candidate(
                slug: slug,
                platform: .cursor,
                scope: "user",
                projectIdentityKey: nil,
                artifactPath: record.targetPath
            ))
        }
        return candidates
    }

    private func projectScopedCandidates(
        from deployRecords: [DeployRecord],
        skillsByID: [UUID: Skill],
        projectsByID: [UUID: Project]
    ) -> [Candidate] {
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for record in deployRecords {
            guard let projectID = record.projectID,
                  let skill = skillsByID[record.skillID],
                  let project = projectsByID[projectID],
                  ProjectDirectory.canAccess(project.path) else { continue }

            if record.platform.usesSymlinks {
                let expectedLink = DeployPaths.linkPath(
                    directoryName: skill.directoryName,
                    platform: record.platform,
                    projectPath: project.path
                )
                let expectedTarget = DeployPaths.targetPath(
                    directoryName: skill.directoryName,
                    platform: record.platform,
                    projectPath: project.path
                )
                guard record.targetPath == expectedLink,
                      fileService.isSymlink(at: record.targetPath),
                      (try? fileService.symlinkTarget(at: record.targetPath)) == expectedTarget else { continue }
            } else {
                let expectedPath = DeployPaths.cursorPath(directoryName: skill.directoryName, projectPath: project.path)
                guard record.targetPath == expectedPath,
                      fileService.fileExists(at: record.targetPath) else { continue }
            }

            guard seen.insert(record.targetPath).inserted else { continue }
            candidates.append(Candidate(
                slug: skill.directoryName,
                platform: record.platform,
                scope: "project",
                projectIdentityKey: project.identityKey,
                artifactPath: record.targetPath
            ))
        }
        return candidates
    }

    private func isRealpathContained(_ dir: String) -> Bool {
        let parent = (dir as NSString).deletingLastPathComponent
        let last = (dir as NSString).lastPathComponent
        let realDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let realParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
        return realDir == realParent + "/" + last
    }

    private var recordedAtFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
