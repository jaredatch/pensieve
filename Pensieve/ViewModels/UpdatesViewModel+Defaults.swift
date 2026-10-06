import Foundation
import SwiftData

extension UpdatesViewModel {
    struct DefaultOperations {
        let updateCheckService: UpdateCheckService
        let skillInstallService: SkillInstallService

        var rowLoader: RowLoader {
            { try UpdatesViewModel.defaultRowLoader(service: updateCheckService, container: $0) }
        }

        var applyOperation: ApplyOperation {
            { skillID, expectedCommit, expectedTree, allowOverwrite, registration, container in
                try UpdatesViewModel.defaultApplyOperation(
                    updateCheckService: updateCheckService,
                    skillInstallService: skillInstallService,
                    request: DefaultApplyRequest(
                        skillID: skillID,
                        expectedCommit: expectedCommit,
                        expectedTree: expectedTree,
                        allowLocalOverwrite: allowOverwrite,
                        bodyWriteRegistration: registration
                    ),
                    container: container
                )
            }
        }

        var diffOperation: UpdateReviewOperations.DiffOperation {
            { row, container in
                try UpdatesViewModel.defaultDiffOperation(skillInstallService: skillInstallService,
                                                          row: row, container: container)
            }
        }

        var recheckOperation: RecheckOperation {
            { skillID, container in
                try UpdatesViewModel.defaultRecheckOperation(
                    service: updateCheckService,
                    skillID: skillID,
                    container: container
                )
            }
        }
    }

    private struct DefaultApplyRequest {
        let skillID: UUID
        let expectedCommit: String
        let expectedTree: String
        let allowLocalOverwrite: Bool
        let bodyWriteRegistration: SyncBodyWriteRegistration
    }

    nonisolated static func findSkill(_ id: UUID, context: ModelContext) throws -> Skill? {
        var descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    nonisolated static func defaultRowLoader(
        service: UpdateCheckService,
        container: ModelContainer
    ) throws -> [UpdatesRow] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<Skill>())
            .filter(isEligibleForUpdates)
            .map { skill in
                try makeRow(skill: skill, driftedLocally: service.driftedLocally(skill: skill))
            }
            .sorted { $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending }
    }

    private nonisolated static func defaultApplyOperation(
        updateCheckService: UpdateCheckService,
        skillInstallService: SkillInstallService,
        request: DefaultApplyRequest,
        container: ModelContainer
    ) throws -> SkillUpdateCompletion {
        let context = ModelContext(container)
        guard let skill = try findSkill(request.skillID, context: context) else {
            throw SkillUpdateFlowError.skillNotFound
        }
        guard skill.upstreamCommit == request.expectedCommit,
              skill.upstreamTree == request.expectedTree else {
            throw SkillUpdateFlowError.repositoryChanged
        }
        let drifted = try updateCheckService.driftedLocally(skill: skill)
        guard !drifted || request.allowLocalOverwrite else {
            throw SkillUpdateFlowError.localEditsRequireConfirmation
        }
        let update = try PinnedSkillUpdate(skill: skill)
        try skillInstallService.applyUpdate(
            update,
            allowLocalOverwrite: request.allowLocalOverwrite,
            bodyWriteRegistration: request.bodyWriteRegistration,
            context: context
        )
        guard let originData = skill.installedOriginData else {
            throw SyncedStateMutationError(underlyingError: SkillUpdateFlowError.skillNotFound)
        }
        return SkillUpdateCompletion(
            skillID: skill.id,
            name: skill.name,
            skillDescription: skill.skillDescription,
            installedOriginData: originData,
            updatedAt: skill.updatedAt
        )
    }

    nonisolated static func defaultDiffOperation(
        skillInstallService: SkillInstallService,
        row: UpdatesRow,
        container: ModelContainer
    ) throws -> PinnedSkillDiff {
        let context = ModelContext(container)
        guard let skill = try findSkill(row.id, context: context) else { throw SkillUpdateFlowError.skillNotFound }
        guard skill.installedOrigin?.installedCommit == row.installedCommit,
              skill.upstreamCommit == row.upstreamCommit,
              skill.upstreamTree == row.upstreamTree else {
            throw SkillUpdateFlowError.repositoryChanged
        }
        guard isEligibleForUpdates(skill) else { throw SkillUpdateFlowError.missingPinnedUpdate }
        return try skillInstallService.previewUpdate(PinnedSkillUpdate(skill: skill))
    }

    nonisolated static func defaultRecheckOperation(
        service: UpdateCheckService,
        skillID: UUID,
        container: ModelContainer
    ) throws -> SkillUpdateRecheckCompletion {
        try service.check(skillID: skillID, context: ModelContext(container))
        let context = ModelContext(container)
        guard let skill = try findSkill(skillID, context: context) else { throw SkillUpdateFlowError.skillNotFound }
        let row: UpdatesRow?
        if isEligibleForUpdates(skill) {
            let drifted = try service.driftedLocally(skill: skill)
            row = try makeRow(skill: skill, driftedLocally: drifted)
        } else {
            row = nil
        }
        return SkillUpdateRecheckCompletion(
            row: row,
            skillID: skill.id,
            updateAvailable: skill.updateAvailable,
            lastCheckedAt: skill.lastCheckedAt,
            lastCheckedHead: skill.lastCheckedHead,
            upstreamTree: skill.upstreamTree,
            upstreamCommit: skill.upstreamCommit,
            upstreamCommitDate: skill.upstreamCommitDate,
            checkError: skill.checkError
        )
    }

    nonisolated static func makeRow(skill: Skill, driftedLocally: Bool) throws -> UpdatesRow {
        guard let origin = skill.installedOrigin, origin != .empty,
              let upstreamCommit = skill.upstreamCommit, !upstreamCommit.isEmpty,
              let upstreamTree = skill.upstreamTree, !upstreamTree.isEmpty,
              let upstreamDate = skill.upstreamCommitDate else {
            throw SkillUpdateFlowError.missingPinnedUpdate
        }
        let parsedRepository = validatedRepository(origin.repo)
        return UpdatesRow(
            id: skill.id,
            skillName: skill.name,
            slug: skill.directoryName,
            installedDate: origin.installedAt,
            installedCommit: origin.installedCommit,
            updateDate: upstreamDate,
            upstreamCommit: upstreamCommit,
            upstreamTree: upstreamTree,
            repositoryDisplay: repositoryDisplay(parsedRepository),
            repositoryPath: origin.path,
            driftedLocally: driftedLocally,
            compareURL: compareURL(
                parsedRepository: parsedRepository,
                installedCommit: origin.installedCommit,
                upstreamCommit: upstreamCommit
            )
        )
    }

    nonisolated static func compareURL(origin: InstalledOrigin, upstreamCommit: String) -> URL? {
        compareURL(
            parsedRepository: validatedRepository(origin.repo),
            installedCommit: origin.installedCommit,
            upstreamCommit: upstreamCommit
        )
    }

    nonisolated static func isCommitSHA(_ value: String) -> Bool {
        let count = value.count
        return count >= 7 && count <= 40
            && value.allSatisfy {
                $0.isASCII && $0.isHexDigit && ($0.isNumber || $0.isLowercase)
            }
    }

    private nonisolated static func validatedRepository(_ repo: String) -> SkillInstallURL? {
        guard let parsed = SkillInstallURL.parse(repo), parsed.form == .repo else { return nil }
        return parsed
    }

    private nonisolated static func repositoryDisplay(_ parsed: SkillInstallURL?) -> String {
        guard let parsed,
              let components = URLComponents(string: parsed.repo) else { return "" }
        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count == 2 else { return "" }
        var repository = segments[1]
        if repository.hasSuffix(".git") {
            repository.removeLast(4)
        }
        return "\(segments[0])/\(repository)"
    }

    private nonisolated static func compareURL(
        parsedRepository: SkillInstallURL?,
        installedCommit: String,
        upstreamCommit: String
    ) -> URL? {
        guard isCommitSHA(installedCommit), isCommitSHA(upstreamCommit),
              let parsedRepository,
              var components = URLComponents(string: parsedRepository.repo) else { return nil }
        let base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [
            base,
            "compare",
            installedCommit + "..." + upstreamCommit
        ].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }
}
