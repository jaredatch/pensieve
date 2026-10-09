import Foundation
import Observation
import SwiftData

struct SkillProvenance: Equatable {
    let installedAt: Date?
    let updatedAt: Date?
    let trackedRef: String?
    let shortCommit: String?
    let repositoryURL: URL?
    let skillURL: URL?
    let localEditNote: String?
    let checkError: String?
    let updateAvailable: Bool
}

struct SkillUpdateCheckResult: Equatable {
    let updateAvailable: Bool?
    let checkError: String?
}

@MainActor
@Observable
final class SkillProvenanceViewModel {
    typealias DriftOperation = (UUID, ModelContainer) throws -> Bool
    typealias CheckOperation = (UUID, ModelContainer) throws -> SkillUpdateCheckResult
    typealias UpdateCheckServiceFactory = () -> UpdateCheckService

    private(set) var checkingSkillIDs: Set<UUID> = []

    private var localDrift: [UUID: Bool] = [:]
    private var driftErrors: [UUID: String] = [:]
    private var transientCheckErrors: [UUID: String] = [:]
    private var checkOperationIDs: [UUID: UUID] = [:]
    private var checkTasks: [UUID: Task<Void, Never>] = [:]
    private let driftOperation: DriftOperation
    private let checkOperation: CheckOperation

    init(
        driftOperation: @escaping DriftOperation,
        checkOperation: @escaping CheckOperation
    ) {
        self.driftOperation = driftOperation
        self.checkOperation = checkOperation
    }

    func provenance(for skill: Skill) -> SkillProvenance? {
        guard let origin = skill.installedOrigin, origin != .empty else { return nil }
        return Self.provenance(
            origin: origin,
            driftedLocally: localDrift[skill.id] ?? false,
            checkError: transientCheckErrors[skill.id] ?? skill.checkError,
            updateAvailable: skill.updateAvailable
        )
    }

    static func provenance(
        origin: InstalledOrigin,
        driftedLocally: Bool,
        checkError: String?,
        updateAvailable: Bool = false
    ) -> SkillProvenance {
        SkillProvenance(
            installedAt: meaningfulDate(origin.installedAt),
            updatedAt: meaningfulDate(origin.updatedAt),
            trackedRef: origin.ref.isEmpty ? nil : origin.ref,
            shortCommit: origin.installedCommit.isEmpty
                ? nil
                : String(origin.installedCommit.prefix(7)),
            repositoryURL: repositoryURL(origin: origin),
            skillURL: skillURL(origin: origin),
            localEditNote: driftedLocally ? "This copy has local edits" : nil,
            checkError: checkError,
            updateAvailable: updateAvailable
        )
    }

    func present(skillID: UUID, context: ModelContext) async {
        let container = context.container
        let operation = driftOperation
        let task = BlockingWork.task(priority: .utility) {
            try Task.checkCancellation()
            return try operation(skillID, container)
        }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(drifted):
            localDrift[skillID] = drifted
            driftErrors[skillID] = nil
        case let .failure(error):
            driftErrors[skillID] = Self.readable(error)
        }
    }

    func recordAdoption(_ completion: SkillInstallAdoptionCompletion, on skill: Skill) {
        skill.installedOriginData = completion.installedOriginData
        skill.resetUpdateCheckState()
        localDrift[completion.skillID] = completion.localDrift
        driftErrors[completion.skillID] = nil
    }

    func recordCheckResult(_ result: SkillUpdateCheckResult, on skill: Skill) {
        if let updateAvailable = result.updateAvailable {
            skill.updateAvailable = updateAvailable
        }
        skill.checkError = result.checkError
        transientCheckErrors[skill.id] = nil
    }

    func driftError(for skillID: UUID) -> String? {
        driftErrors[skillID]
    }

    func checkForUpdates(skillID: UUID, context: ModelContext) {
        guard !checkingSkillIDs.contains(skillID) else { return }
        let id = UUID()
        checkOperationIDs[skillID] = id
        checkingSkillIDs.insert(skillID)
        let container = context.container
        checkTasks[skillID] = Task {
            await performCheck(
                skillID: skillID,
                context: context,
                container: container,
                operationID: id
            )
        }
    }

    func isChecking(skillID: UUID) -> Bool {
        checkingSkillIDs.contains(skillID)
    }

    func cancelCheck(skillID: UUID) {
        checkTasks[skillID]?.cancel()
        checkTasks[skillID] = nil
        checkOperationIDs[skillID] = nil
        checkingSkillIDs.remove(skillID)
    }

    static func readable(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    nonisolated static func makeDriftOperation(
        serviceFactory: @escaping UpdateCheckServiceFactory
    ) -> DriftOperation {
        { skillID, container in
            let context = ModelContext(container)
            guard let skill = try context.fetch(FetchDescriptor<Skill>()).first(where: {
                $0.id == skillID
            }) else { return false }
            return try serviceFactory().driftedLocally(skill: skill)
        }
    }

    nonisolated static func makeCheckOperation(
        serviceFactory: @escaping UpdateCheckServiceFactory
    ) -> CheckOperation {
        { skillID, container in
            let service = serviceFactory()
            try service.check(skillID: skillID, context: ModelContext(container))
            let context = ModelContext(container)
            let skill = try context.fetch(FetchDescriptor<Skill>()).first(where: { $0.id == skillID })
            return SkillUpdateCheckResult(
                updateAvailable: skill?.updateAvailable,
                checkError: skill?.checkError
            )
        }
    }
}

private extension SkillProvenanceViewModel {
    func performCheck(
        skillID: UUID,
        context: ModelContext,
        container: ModelContainer,
        operationID: UUID
    ) async {
        guard checkOperationIDs[skillID] == operationID, !Task.isCancelled else { return }
        let operation = checkOperation
        let task = BlockingWork.task(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation(skillID, container)
        }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        guard checkOperationIDs[skillID] == operationID, !Task.isCancelled else { return }
        switch result {
        case let .success(value):
            apply(value, skillID: skillID, context: context)
            transientCheckErrors[skillID] = nil
        case let .failure(error):
            transientCheckErrors[skillID] = Self.readable(SkillInstallService.mappedRepositoryError(error))
        }
        checkingSkillIDs.remove(skillID)
        checkOperationIDs[skillID] = nil
        checkTasks[skillID] = nil
    }

    func apply(_ result: SkillUpdateCheckResult, skillID: UUID, context: ModelContext) {
        let skill = try? context.fetch(FetchDescriptor<Skill>()).first(where: { $0.id == skillID })
        guard let skill else { return }
        recordCheckResult(result, on: skill)
    }

    static func skillURL(origin: InstalledOrigin) -> URL? {
        guard !origin.path.isEmpty,
              isSafeGitHubLinkPath(origin.ref),
              isSafeGitHubLinkPath(origin.path),
              let repositoryURL = repositoryURL(origin: origin),
              var components = URLComponents(url: repositoryURL, resolvingAgainstBaseURL: false),
              !origin.ref.isEmpty else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = ["tree", origin.ref, origin.path]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }

    static func isSafeGitHubLinkPath(_ value: String) -> Bool {
        let segments = PathSyntax.components(value, omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy {
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && !$0.contains("..")
                && !PathSyntax.startsWithDash($0)
                && !$0.contains("\\")
        }
    }

    static func repositoryURL(origin: InstalledOrigin) -> URL? {
        guard let parsed = SkillInstallURL.parse(origin.repo), parsed.form == .repo else {
            return nil
        }
        return URL(string: parsed.repo)
    }

    static func meaningfulDate(_ date: Date) -> Date? {
        date.timeIntervalSince1970 > 0 ? date : nil
    }

}
