import Foundation
import SwiftData

extension UpdatesViewModel {
    func performLoad(context: ModelContext, operationID id: UUID) async {
        guard operationID == id, !Task.isCancelled else { return }
        let container = context.container
        let loader = rowLoader
        let task = Task.detached(priority: .userInitiated) {
            try Self.performUnlessCancelled { try loader(container) }
        }
        backgroundCancel = { task.cancel() }
        do {
            let loaded = try await task.value
            guard operationID == id, !Task.isCancelled else { return }
            rows = loaded
            let available = Set(loaded.map(\.id))
            let skills = try context.fetch(FetchDescriptor<Skill>()).filter { available.contains($0.id) }
            presentationSkills = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
            selectedSkillIDs = initialSelection.map { $0.intersection(available) } ?? available
            confirmedDriftSkillIDs.formIntersection(Set(loaded.map(\.id)))
            statuses = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, .idle) })
            loadError = nil
        } catch {
            guard operationID == id, !Task.isCancelled else { return }
            loadError = Self.readable(error)
        }
        isLoading = false
        finishOperation(id)
    }

    func performApply(rows selectedRows: [UpdatesRow], container: ModelContainer,
                      presentationContext: ModelContext,
                      operationID id: UUID) async {
        var didMutate = false
        defer { if didMutate { notifier() } }
        guard operationID == id, !Task.isCancelled else { return }
        for row in selectedRows {
            guard operationID == id, !Task.isCancelled else { return }
            guard canSelect(row) else { continue }
            let confirmed = confirmedDriftSkillIDs.contains(row.id)
            guard !row.driftedLocally || confirmed else {
                statuses[row.id] = .confirmationRequired
                continue
            }
            await performApply(row: row, confirmed: confirmed, container: container,
                               presentationContext: presentationContext, operationID: id, onMutation: { didMutate = true })
        }
        guard operationID == id else { return }
        isApplyingBatch = false
        finishOperation(id)
    }

    private func performApply(row: UpdatesRow, confirmed: Bool, container: ModelContainer,
                              presentationContext: ModelContext, operationID id: UUID, onMutation: @escaping () -> Void) async {
        guard applyCoordinator.begin(row.id) else { return }
        statuses[row.id] = .updating
        let apply = applyOperation
        let bodyWriteRegistration = bodyWriteRegistration
        let task = Task.detached(priority: .userInitiated) {
            try Self.performUnlessCancelled {
                try apply(row.id, row.upstreamCommit, row.upstreamTree, confirmed, bodyWriteRegistration, container)
            }
        }
        backgroundCancel = { task.cancel() }
        let result = await task.result
        let status = UpdateReviewResult.apply(result).resolve(
            row: row, context: presentationContext,
            effects: UpdateReviewEffects(echo: echoRegistrar, notify: onMutation, invalidateEditorBody: invalidateEditorBody)
        )
        // Canonical-write effects still run after cancellation, but a retired session cannot publish a failure.
        let retired = operationID != id || Task.isCancelled
        let published: UpdatesRowStatus?
        if case .success = result { published = status } else { published = retired || status == .idle ? nil : status }
        applyCoordinator.finish(row: row, status: published, context: presentationContext)
    }

    func performRecheck(row: UpdatesRow, container: ModelContainer,
                        presentationContext: ModelContext,
                        operationID id: UUID) async {
        defer {
            if operationID == id || operationID == nil,
               recheckingSkillID == row.id {
                recheckingSkillID = nil
            }
        }
        guard operationID == id, !Task.isCancelled else { return }
        let recheck = recheckOperation
        let task = Task.detached(priority: .userInitiated) {
            try Self.performUnlessCancelled { try recheck(row.id, container) }
        }
        backgroundCancel = { task.cancel() }
        let result = await task.result
        guard operationID == id, !Task.isCancelled else { return }
        let status = UpdateReviewResult.recheck(result).resolve(
            row: row, context: presentationContext,
            effects: UpdateReviewEffects(echo: echoRegistrar, notify: notifier, invalidateEditorBody: invalidateEditorBody)
        )
        statuses[row.id] = status
        if case .idle = status, case let .success(completion) = result {
            if let refreshed = completion.row, let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index] = refreshed
            } else {
                rows.removeAll { $0.id == row.id }
                selectedSkillIDs.remove(row.id)
                confirmedDriftSkillIDs.remove(row.id)
                statuses[row.id] = nil
            }
        }
        finishOperation(id)
    }

    func beginOperation() -> UUID {
        operationID = nil
        operationTask?.cancel()
        backgroundCancel?()
        let id = UUID()
        operationID = id
        operationTask = nil
        backgroundCancel = nil
        return id
    }

    func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        operationTask = nil
        backgroundCancel = nil
    }

    static func applyCompletion(_ completion: SkillUpdateCompletion, context: ModelContext) {
        guard let skill = try? Self.findSkill(completion.skillID, context: context) else { return }
        skill.name = completion.name
        skill.skillDescription = completion.skillDescription
        skill.installedOriginData = completion.installedOriginData
        skill.updatedAt = completion.updatedAt
        skill.resetUpdateCheckState()
    }

    static func applyRecheckCompletion(_ completion: SkillUpdateRecheckCompletion, context: ModelContext) {
        guard let skill = try? Self.findSkill(completion.skillID, context: context) else { return }
        skill.updateAvailable = completion.updateAvailable
        skill.lastCheckedAt = completion.lastCheckedAt
        skill.lastCheckedHead = completion.lastCheckedHead
        skill.upstreamTree = completion.upstreamTree
        skill.upstreamCommit = completion.upstreamCommit
        skill.upstreamCommitDate = completion.upstreamCommitDate
        skill.checkError = completion.checkError
    }

    nonisolated static func performUnlessCancelled<T>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try body()
    }

    nonisolated static func readable(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    nonisolated static func offersRecheck(_ error: Error) -> Bool {
        error as? SkillUpdateFlowError == .repositoryChanged
            || error as? SkillUpdateFlowError == .missingPinnedUpdate
    }
}
