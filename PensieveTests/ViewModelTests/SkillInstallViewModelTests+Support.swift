import SwiftData
import XCTest
@testable import Pensieve

extension SkillInstallViewModelTests {
    final class ScriptedInstallService: SkillInstallServiceProtocol {
        let candidates: [SkillCandidate]
        var collisionSlugs: Set<String> = []
        var failingSlugs: Set<String> = []
        var fetchGate: TestWait.Gate?
        var installGate: TestWait.Gate?
        let fetchStarted = DispatchSemaphore(value: 0)
        let installStarted = DispatchSemaphore(value: 0)

        private let lock = NSLock()
        private var fetchDidComplete = false
        private var installCalls = 0
        private var adopted: [String] = []
        private var renamed: [String] = []
        private var fetchMainThread = true
        private var installMainThread = true

        init(candidates: [SkillCandidate]) {
            self.candidates = candidates
        }

        var fetchCompleted: Bool { locked { fetchDidComplete } }
        var installCallCount: Int { locked { installCalls } }
        var adoptedSlugs: [String] { locked { adopted } }
        var renamedSlugs: [String] { locked { renamed } }
        var fetchedOnMainThread: Bool { locked { fetchMainThread } }
        var installedOnMainThread: Bool { locked { installMainThread } }

        func fetch(repo: String, ref: String?, credential: GitCredential?) throws -> SkillFetchResult {
            locked { fetchMainThread = Thread.isMainThread }
            fetchStarted.signal()
            if let fetchGate { try fetchGate.wait() }
            locked { fetchDidComplete = true }
            return result(repo: repo, ref: ref)
        }

        func fetch(repo: String, ref: String?, path: String,
                   credential: GitCredential?) throws -> SkillFetchResult {
            try fetch(repo: repo, ref: ref, credential: credential)
        }

        func install(candidate: SkillCandidate, from source: SkillFetchResult,
                     credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                     context: ModelContext) throws -> SkillInstallResult {
            // Record the call before signaling: a test that wakes on `installStarted` reads `installCallCount`
            // at once, and a signal sent first let it read 0 under load (#46).
            locked {
                installCalls += 1
                installMainThread = Thread.isMainThread
            }
            installStarted.signal()
            if let installGate { try installGate.wait() }
            if failingSlugs.contains(candidate.slug) { throw TestError.installFailed }
            if collisionSlugs.contains(candidate.slug) {
                return .collision(existing: SkillCollision(
                    slug: candidate.slug, hasDirectory: true, hasSwiftDataRow: true
                ))
            }
            return .installed(slug: candidate.slug)
        }

        func install(candidate: SkillCandidate, renamedTo slug: String, from source: SkillFetchResult,
                     credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                     context: ModelContext) throws -> SkillInstallResult {
            locked { renamed.append(slug) }
            return .installed(slug: slug)
        }

        func adopt(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                   credential: GitCredential?, context: ModelContext) throws -> SkillAdoptResult {
            locked { adopted.append(existingSlug) }
            return .clean
        }

        func update(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                    credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                    context: ModelContext) throws {}

        private func result(repo: String, ref: String?) -> SkillFetchResult {
            SkillFetchResult(repo: repo, ref: ref ?? "main", headCommit: "head", candidates: candidates)
        }

        @discardableResult
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    enum TestError: LocalizedError {
        case installFailed

        var errorDescription: String? { "fixture install failed" }
    }

    func candidate(_ slug: String) -> SkillCandidate {
        SkillCandidate(
            path: "skills/\(slug)",
            slug: slug,
            name: slug.capitalized,
            skillDescription: "Description for \(slug)",
            treeHash: "tree-\(slug)",
            containsSymlink: false,
            unavailableReason: nil
        )
    }

    func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            ScenarioAssignment.self, DeployRecord.self, Pensieve.Category.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func makeModel(
        service: SkillInstallServiceProtocol,
        repository: String = "/fixture"
    ) -> SkillInstallViewModel {
        SkillInstallViewModel(service: service) { _ in
            .success(SkillInstallURL(
                repo: repository,
                cloneRemote: repository,
                ref: nil,
                path: nil,
                form: .repo
            ))
        }
    }

    func makeRealService() -> SkillInstallService {
        SkillInstallService(
            gitService: GitService(fileService: fileService, askpassHelperPath: TestPaths.gitAskpassHelperPath),
            credentialStore: InMemoryCredentialStore(),
            fileService: fileService,
            scratchRoot: tempDir + "/scratch",
            storeRoot: tempDir + "/store",
            manifestService: ManifestService(fileService: fileService),
            lockPath: tempDir + "/sync.lock",
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
    }

    func makeRepository(named name: String) throws -> String {
        let path = tempDir + "/" + name
        let result = try rawGit(["init", "--initial-branch=main", path])
        XCTAssertEqual(result.exit, 0, result.stderr)
        return path
    }

    func writeSkill(_ relativeDirectory: String, name: String, description: String,
                    in repository: String) throws {
        try fileService.writeFile(
            at: repository + "/" + relativeDirectory + "/SKILL.md",
            content: "---\nname: \(name)\ndescription: \(description)\n---\nbody\n"
        )
    }

    func commit(_ repository: String) throws {
        let add = try rawGit(["-C", repository, "add", "-A"])
        XCTAssertEqual(add.exit, 0, add.stderr)
        let commit = try rawGit([
            "-C", repository, "-c", "user.email=t@t", "-c", "user.name=t",
            "commit", "-m", "seed"
        ])
        XCTAssertEqual(commit.exit, 0, commit.stderr)
    }

    struct RawGitResult {
        let stderr: String
        let exit: Int32
    }

    func rawGit(_ arguments: [String]) throws -> RawGitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return RawGitResult(
            stderr: String(bytes: data, encoding: .utf8) ?? "",
            exit: process.terminationStatus
        )
    }

}
