import Foundation

struct UpdatesRow: Identifiable, Equatable {
    let id: UUID
    let skillName: String
    let slug: String
    let installedDate: Date
    let installedCommit: String
    let updateDate: Date
    let upstreamCommit: String
    let upstreamTree: String
    let repositoryDisplay: String
    let repositoryPath: String
    let driftedLocally: Bool
    let compareURL: URL?

    var shortInstalledCommit: String { String(installedCommit.prefix(7)) }
    var shortUpstreamCommit: String { String(upstreamCommit.prefix(7)) }

    func markedDrifted() -> UpdatesRow {
        UpdatesRow(
            id: id,
            skillName: skillName,
            slug: slug,
            installedDate: installedDate,
            installedCommit: installedCommit,
            updateDate: updateDate,
            upstreamCommit: upstreamCommit,
            upstreamTree: upstreamTree,
            repositoryDisplay: repositoryDisplay,
            repositoryPath: repositoryPath,
            driftedLocally: true,
            compareURL: compareURL
        )
    }
}

enum UpdatesRowStatus: Equatable {
    case idle
    case confirmationRequired
    case updating
    case updated
    case failed(message: String, offersRecheck: Bool)
}

struct UpdatesDiffPresentation: Identifiable, Equatable {
    let id: UUID
    let skillName: String
    let repositoryDisplay: String
    let repositoryPath: String
    let currentSkillMarkdown: String
    let upstreamSkillMarkdown: String
    let compareURL: URL?
}

struct SkillUpdateCompletion: Equatable {
    let skillID: UUID
    let name: String
    let skillDescription: String
    let installedOriginData: Data
    let updatedAt: Date
}

struct SkillUpdateRecheckCompletion: Equatable {
    let row: UpdatesRow?
    let skillID: UUID
    let updateAvailable: Bool
    let lastCheckedAt: Date?
    let lastCheckedHead: String?
    let upstreamTree: String?
    let upstreamCommit: String?
    let upstreamCommitDate: Date?
    let checkError: String?
}
