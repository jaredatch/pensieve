import SwiftData

extension SkillInstallServiceProtocol {
    func install(candidate: SkillCandidate, from source: SkillFetchResult,
                 credential: GitCredential?, context: ModelContext) throws -> SkillInstallResult {
        try install(
            candidate: candidate, from: source, credential: credential,
            bodyWriteRegistration: .suppressed, context: context
        )
    }

    func install(candidate: SkillCandidate, renamedTo slug: String, from source: SkillFetchResult,
                 credential: GitCredential?, context: ModelContext) throws -> SkillInstallResult {
        try install(
            candidate: candidate, renamedTo: slug, from: source, credential: credential,
            bodyWriteRegistration: .suppressed, context: context
        )
    }

    func update(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                credential: GitCredential?, context: ModelContext) throws {
        try update(
            existingSlug: existingSlug, candidate: candidate, from: source, credential: credential,
            bodyWriteRegistration: .suppressed, context: context
        )
    }
}
