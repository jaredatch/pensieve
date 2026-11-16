import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func nativePreview(_ service: SkillInstallService, skill: Skill) throws -> PinnedSkillDiff {
        let update = try PinnedSkillUpdate(skill: skill)
        return try NativeTestWork.run { try service.previewUpdate(update) }
    }

    struct RealFixture {
        let repository: String
        let storeRoot: String
        let service: SkillInstallService
        let skill: Skill
        let pinnedCommit: String
    }

    enum FixtureError: LocalizedError {
        case expectedFailure
        var errorDescription: String? { "fixture update failed" }
    }

    final class LockedCallRecorder {
        private let lock = NSLock()
        private var recorded: [UUID] = []
        var values: [UUID] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
        func append(_ value: UUID) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(value)
        }
    }

    final class LockedBoolRecorder {
        private let lock = NSLock()
        private var recorded: [Bool] = []
        var values: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
        func append(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(value)
        }
    }

    func insertUpdateSkill(slug: String) -> Skill {
        let skill = Skill(name: slug.capitalized, skillDescription: "Description", directoryName: slug)
        skill.installedOrigin = InstalledOrigin(
            repo: "https://github.com/example/repository",
            path: "skills/\(slug)",
            ref: "main",
            installedCommit: String(repeating: "1", count: 40),
            installedTree: "installed-tree-\(slug)",
            contentHash: "content-\(slug)",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        skill.updateAvailable = true
        skill.upstreamTree = "upstream-tree-\(slug)"
        skill.upstreamCommit = String(repeating: "2", count: 40)
        skill.upstreamCommitDate = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(skill)
        return skill
    }

    func makeModel(
        rows: [UpdatesRow],
        recheck: @escaping UpdatesViewModel.RecheckOperation = { id, _ in
            SkillUpdateRecheckCompletion(
                row: nil,
                skillID: id,
                updateAvailable: false,
                lastCheckedAt: nil,
                lastCheckedHead: nil,
                upstreamTree: nil,
                upstreamCommit: nil,
                upstreamCommitDate: nil,
                checkError: nil
            )
        },
        apply: @escaping UpdatesViewModel.ApplyOperation = { id, _, _, _, _, container in
            let context = ModelContext(container)
            guard let skill = try context.fetch(FetchDescriptor<Skill>()).first(where: {
                $0.id == id
            }), let data = skill.installedOriginData else {
                throw SkillUpdateFlowError.skillNotFound
            }
            return SkillUpdateCompletion(
                skillID: id,
                name: skill.name,
                skillDescription: skill.skillDescription,
                installedOriginData: data,
                updatedAt: skill.updatedAt
            )
        }
    ) -> UpdatesViewModel {
        UpdatesViewModel(
            rowLoader: { _ in rows },
            applyOperation: apply,
            recheckOperation: recheck
        )
    }

    func completion(for skill: Skill) throws -> SkillUpdateCompletion {
        SkillUpdateCompletion(
            skillID: skill.id,
            name: skill.name,
            skillDescription: skill.skillDescription,
            installedOriginData: try XCTUnwrap(skill.installedOriginData),
            updatedAt: skill.updatedAt
        )
    }

    func makeRealModel(fixture: RealFixture, service: SkillInstallService? = nil) -> UpdatesViewModel {
        let checker = UpdateCheckService(
            gitService: GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass"),
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            contentHasher: fixture.service,
            scratchRoot: tempDir + "/check-scratch",
            storeRoot: fixture.storeRoot,
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
        let operations = UpdatesViewModel.DefaultOperations(
            updateCheckService: checker,
            skillInstallService: service ?? fixture.service
        )
        return UpdatesViewModel(
            rowLoader: operations.rowLoader,
            applyOperation: operations.applyOperation,
            recheckOperation: { id, _ in Self.noUpdateRecheckCompletion(skillID: id) }
        )
    }

    nonisolated static func noUpdateRecheckCompletion(
        skillID: UUID
    ) -> SkillUpdateRecheckCompletion {
        SkillUpdateRecheckCompletion(
            row: nil,
            skillID: skillID,
            updateAvailable: false,
            lastCheckedAt: nil,
            lastCheckedHead: nil,
            upstreamTree: nil,
            upstreamCommit: nil,
            upstreamCommitDate: nil,
            checkError: nil
        )
    }

    nonisolated static func refreshedRecheckCompletion(
        row: UpdatesRow,
        skillID: UUID
    ) -> SkillUpdateRecheckCompletion {
        SkillUpdateRecheckCompletion(
            row: row,
            skillID: skillID,
            updateAvailable: true,
            lastCheckedAt: Date(),
            lastCheckedHead: row.upstreamCommit,
            upstreamTree: row.upstreamTree,
            upstreamCommit: row.upstreamCommit,
            upstreamCommitDate: row.updateDate,
            checkError: nil
        )
    }

    func prepareRealPinnedUpdate(includingCompanionFiles: Bool = false) throws -> RealFixture {
        let repository = tempDir + "/repository"
        XCTAssertEqual(try rawGit(["init", "--initial-branch=main", repository]), 0)
        try writeSkill(name: "Old Name", description: "Old Description", body: "old body",
                       repository: repository)
        if includingCompanionFiles { try writeCompanionFiles(body: "old body", repository: repository) }
        _ = try commit(repository, message: "installed")
        let storeRoot = tempDir + "/store"
        let service = SkillInstallService(
            gitService: GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass"),
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: tempDir + "/install-scratch",
            storeRoot: storeRoot,
            manifestService: ManifestService(fileService: fileService),
            lockPath: tempDir + "/sync.lock",
            now: { Date(timeIntervalSince1970: 1_850_000_000) },
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
        let installedSource = try NativeTestWork.run {
            try service.fetch(repo: "file://" + repository, ref: nil, credential: nil)
        }
        let installedCandidate = try XCTUnwrap(installedSource.candidates.first)
        _ = try NativeTestWork.run(container: context.container) { [self] jobContext in
            try service.install(candidate: installedCandidate, from: installedSource, context: jobContext)
        }
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)

        try writeSkill(name: "Fresh Name", description: "Fresh Description", body: "fresh body",
                       repository: repository)
        if includingCompanionFiles { try writeCompanionFiles(body: "fresh body", repository: repository) }
        let pinnedCommit = try commit(repository, message: "checked update")
        let updateSource = try NativeTestWork.run {
            try service.fetch(repo: "file://" + repository, ref: nil, credential: nil)
        }
        let updateCandidate = try XCTUnwrap(updateSource.candidates.first)
        skill.updateAvailable = true
        skill.upstreamTree = updateCandidate.treeHash
        skill.upstreamCommit = pinnedCommit
        skill.upstreamCommitDate = Date(timeIntervalSince1970: 1_860_000_000)
        skill.checkError = nil
        if includingCompanionFiles {
            skill.lastCheckedAt = Date(timeIntervalSince1970: 1_860_000_000)
            skill.lastCheckedHead = pinnedCommit
        }
        try context.save()
        return RealFixture(repository: repository, storeRoot: storeRoot, service: service,
                           skill: skill, pinnedCommit: pinnedCommit)
    }

    func writeSkill(name: String, description: String, body: String,
                    repository: String) throws {
        try fileService.writeFile(
            at: repository + "/skills/vendor/SKILL.md",
            content: "---\nname: \(name)\ndescription: \(description)\n---\n\(body)\n"
        )
    }

    @discardableResult
    func commit(_ repository: String, message: String) throws -> String {
        XCTAssertEqual(try rawGit(["-C", repository, "add", "-A"]), 0)
        XCTAssertEqual(try rawGit([
            "-C", repository, "-c", "user.email=t@t", "-c", "user.name=t",
            "commit", "-m", message
        ]), 0)
        let output = try rawGitOutput(["-C", repository, "rev-parse", "HEAD"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rawGit(_ arguments: [String]) throws -> Int32 {
        try rawGitProcess(arguments).exit
    }

    func rawGitOutput(_ arguments: [String]) throws -> String {
        try rawGitProcess(arguments).output
    }

    func rawGitProcess(_ arguments: [String]) throws -> (exit: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    func writeCompanionFiles(body: String, repository: String) throws {
        try fileService.writeFile(at: repository + "/skills/vendor/companion.txt", content: body + "\n")
        try fileService.writeExecutableFile(at: repository + "/skills/vendor/run.sh",
                                            content: "#!/bin/sh\nprintf '%s\\n' '\(body)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: repository + "/skills/vendor/run.sh")
    }

    struct ApplyFileSnapshot: Equatable {
        let bytes: Data
        let executable: Bool
    }

    struct ApplyRecordSnapshot: Equatable {
        let installedOrigin: InstalledOrigin?
        let name: String
        let skillDescription: String
        let updatedAt: Date
        let updateAvailable: Bool
        let upstreamCommit: String?
        let upstreamTree: String?
        let upstreamCommitDate: Date?
        let lastCheckedAt: Date?
        let lastCheckedHead: String?
        let checkError: String?
    }

    struct ApplySkillSnapshot: Equatable {
        let files: [String: ApplyFileSnapshot]
        let manifest: [String: ApplyFileSnapshot]
        let record: ApplyRecordSnapshot
    }

    func snapshotFiles(at root: String) throws -> [String: ApplyFileSnapshot] {
        var files: [String: ApplyFileSnapshot] = [:]
        func visit(_ directory: String, prefix: String) throws {
            for entry in try fileService.listDirectory(at: directory) {
                let path = directory + "/" + entry
                let relative = prefix + entry
                if fileService.directoryExists(at: path) {
                    try visit(path, prefix: relative + "/")
                } else {
                    files[relative] = ApplyFileSnapshot(bytes: try fileService.readData(at: path),
                                                        executable: fileService.isUserExecutableFile(at: path))
                }
            }
        }
        try visit(root, prefix: "")
        return files
    }

    func snapshotSkill(_ fixture: RealFixture) throws -> ApplySkillSnapshot {
        // Apply persists through its own context; the fixture's held object may be stale.
        let freshContext = ModelContext(container)
        let skill = try XCTUnwrap(try UpdatesViewModel.findSkill(fixture.skill.id, context: freshContext))
        return ApplySkillSnapshot(
            files: try snapshotFiles(at: fixture.storeRoot + "/skills/vendor"),
            manifest: try snapshotFiles(at: fixture.storeRoot + "/manifest"),
            record: ApplyRecordSnapshot(
                installedOrigin: skill.installedOrigin, name: skill.name, skillDescription: skill.skillDescription,
                updatedAt: skill.updatedAt, updateAvailable: skill.updateAvailable,
                upstreamCommit: skill.upstreamCommit, upstreamTree: skill.upstreamTree,
                upstreamCommitDate: skill.upstreamCommitDate, lastCheckedAt: skill.lastCheckedAt,
                lastCheckedHead: skill.lastCheckedHead, checkError: skill.checkError
            )
        )
    }

}
