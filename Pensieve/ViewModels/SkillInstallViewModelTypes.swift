import Foundation
import SwiftData

enum SkillInstallState: Equatable {
    case idle
    case fetching
    case picking
    case installing
    case done
    case failed(String)
}

enum SkillInstallReportKind: Equatable {
    case installed(slug: String)
    case adopted(localDrift: Bool)
    case skipped
    case failed(String)
}

struct SkillInstallReport: Identifiable, Equatable {
    let candidate: SkillCandidate
    let result: SkillInstallReportKind

    var id: String { candidate.path }
}

struct SkillInstallPendingCollision: Equatable {
    let candidate: SkillCandidate
    let existing: SkillCollision

    var canAdopt: Bool {
        existing.hasDirectory && existing.hasSwiftDataRow
    }
}

struct SkillInstallCollisionActionRequest {
    let id: UUID
    let collision: SkillInstallPendingCollision
    let container: ModelContainer
}

struct SkillInstallAdoptTarget: Equatable {
    let skillID: UUID
    let slug: String
    let name: String
}

struct SkillInstallAdoptionCompletion: Equatable {
    let skillID: UUID
    let localDrift: Bool
    let installedOriginData: Data
}

struct SkillInstallTargetedAdoptionResult {
    let result: SkillAdoptResult
    let installedOriginData: Data
}

struct SkillInstallTargetedAdoptionRequest {
    let id: UUID
    let target: SkillInstallAdoptTarget
    let candidate: SkillCandidate
    let source: SkillFetchResult
    let container: ModelContainer
}
