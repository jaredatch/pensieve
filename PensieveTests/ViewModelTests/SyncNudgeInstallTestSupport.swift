import Foundation
import SwiftData
@testable import Pensieve

struct InstallEchoFixture {
    let store: InstallEchoSkillStore
    let watcher: InstallEchoWatcher
    let library: SkillLibraryViewModel
}

final class NudgeInstallService: SkillInstallServiceProtocol {
    let candidates: [SkillCandidate]
    let collisionSlugs: Set<String>
    let beforeInstallReturn: () throws -> Void
    let beforeAdoptReturn: () throws -> Void
    let onInstallWrite: (String) throws -> Void
    let installErrorBeforeWrite: Error?
    let installErrorAfterWrite: Error?
    let adoptErrorAfterWrite: Error?

    init(candidates: [SkillCandidate], collisionSlugs: Set<String> = [],
         beforeInstallReturn: @escaping () throws -> Void = {},
         beforeAdoptReturn: @escaping () throws -> Void = {},
         onInstallWrite: @escaping (String) throws -> Void = { _ in },
         installErrorBeforeWrite: Error? = nil,
         installErrorAfterWrite: Error? = nil,
         adoptErrorAfterWrite: Error? = nil) {
        self.candidates = candidates
        self.collisionSlugs = collisionSlugs
        self.beforeInstallReturn = beforeInstallReturn
        self.beforeAdoptReturn = beforeAdoptReturn
        self.onInstallWrite = onInstallWrite
        self.installErrorBeforeWrite = installErrorBeforeWrite
        self.installErrorAfterWrite = installErrorAfterWrite
        self.adoptErrorAfterWrite = adoptErrorAfterWrite
    }

    func fetch(repo: String, ref: String?, credential: GitCredential?) throws -> SkillFetchResult {
        SkillFetchResult(repo: repo, ref: ref ?? "main", headCommit: "head", candidates: candidates)
    }

    func fetch(repo: String, ref: String?, path: String,
               credential: GitCredential?) throws -> SkillFetchResult {
        try fetch(repo: repo, ref: ref, credential: credential)
    }

    func install(candidate: SkillCandidate, from source: SkillFetchResult,
                 credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                 context: ModelContext) throws -> SkillInstallResult {
        if let installErrorBeforeWrite { throw installErrorBeforeWrite }
        if collisionSlugs.contains(candidate.slug) {
            return .collision(existing: SkillCollision(
                slug: candidate.slug, hasDirectory: true, hasSwiftDataRow: true
            ))
        }
        try performBodyWrite(slug: candidate.slug, registration: bodyWriteRegistration)
        if let installErrorAfterWrite {
            throw SyncedStateMutationError(underlyingError: installErrorAfterWrite)
        }
        return .installed(slug: candidate.slug)
    }

    func install(candidate: SkillCandidate, renamedTo slug: String, from source: SkillFetchResult,
                 credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                 context: ModelContext) throws -> SkillInstallResult {
        if let installErrorBeforeWrite { throw installErrorBeforeWrite }
        try performBodyWrite(slug: slug, registration: bodyWriteRegistration)
        if let installErrorAfterWrite {
            throw SyncedStateMutationError(underlyingError: installErrorAfterWrite)
        }
        return .installed(slug: slug)
    }

    func adopt(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
               credential: GitCredential?, context: ModelContext) throws -> SkillAdoptResult {
        if let skill = try context.fetch(FetchDescriptor<Skill>()).first(where: {
            $0.directoryName == existingSlug
        }) {
            skill.installedOriginData = Data("adopted-origin".utf8)
            try context.save()
        }
        if let adoptErrorAfterWrite {
            throw SyncedStateMutationError(underlyingError: adoptErrorAfterWrite)
        }
        try beforeAdoptReturn()
        return .clean
    }

    func update(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                context: ModelContext) throws {}

    private func performBodyWrite(slug: String, registration: SyncBodyWriteRegistration) throws {
        let raw = SkillSerializer.serialize(
            name: slug, description: "Description", body: "Installed"
        )
        registration.begin(slug, SkillParser.stripFrontmatter(raw))
        var bodyWriteSucceeded = false
        defer { registration.end(slug, bodyWriteSucceeded) }
        try onInstallWrite(slug)
        bodyWriteSucceeded = true
        try beforeInstallReturn()
    }
}

enum NudgeFailure: LocalizedError {
    case beforeCanonicalWrite
    case afterCanonicalWrite

    var errorDescription: String? { "fixture failure" }
}

final class InstallEchoSkillStore: SkillStoreProtocol {
    let baseDir = TestPaths.skillsDir
    var bodies: [String: String] = [:]

    func createSkill(name: String, description: String, body: String) throws -> String { "unused" }
    func readBody(directoryName: String) throws -> String { bodies[directoryName] ?? "" }
    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        return SkillRewriteResult(content: body, didChange: true)
    }
    func writeBody(directoryName: String, body: String) throws {}
    func deleteSkill(directoryName: String) throws {}
    func listSkills() throws -> [String] { Array(bodies.keys) }
}

final class InstallEchoWatcher: FileWatchServiceProtocol {
    var onChange: (String) -> Void = { _ in }
    func start() -> Bool { true }
    func stop() {}
    func emit(_ slug: String) { onChange(slug) }
}
