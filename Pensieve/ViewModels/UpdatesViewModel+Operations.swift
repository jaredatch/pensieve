import Foundation
import SwiftData

extension UpdatesViewModel {
    func performLoad(container: ModelContainer, operationID id: UUID) async {
        guard operationID == id, !Task.isCancelled else { return }
        let loader = rowLoader
        let task = Task.detached(priority: .userInitiated) {
            try Self.performUnlessCancelled { try loader(container) }
        }
        backgroundCancel = { task.cancel() }
        do {
            let loaded = try await task.value
            guard operationID == id, !Task.isCancelled else { return }
            rows = loaded
            hasLoadedRows = true
            let available = Set(loaded.map(\.id))
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
        defer { notifyAfterApplyIfNeeded(didMutate) }
        guard operationID == id, !Task.isCancelled else { return }
        for row in selectedRows {
            guard operationID == id, !Task.isCancelled else { return }
            let confirmed = confirmedDriftSkillIDs.contains(row.id)
            guard !row.driftedLocally || confirmed else {
                statuses[row.id] = .confirmationRequired
                continue
            }
            if await performApply(
                row: row,
                confirmed: confirmed,
                container: container,
                presentationContext: presentationContext,
                operationID: id
            ) {
                didMutate = true
            }
        }
        guard operationID == id else { return }
        isApplying = false
        finishOperation(id)
    }

    private func performApply(row: UpdatesRow, confirmed: Bool, container: ModelContainer,
                              presentationContext: ModelContext, operationID id: UUID) async -> Bool {
        statuses[row.id] = .updating
        let apply = applyOperation
        let bodyWriteRegistration = bodyWriteRegistration
        let task = Task.detached(priority: .userInitiated) {
            try Self.performUnlessCancelled {
                try apply(
                    row.id, row.upstreamCommit, row.upstreamTree, confirmed,
                    bodyWriteRegistration, container
                )
            }
        }
        backgroundCancel = { task.cancel() }
        do {
            let completion = try await task.value
            echoRegistrar([row.slug])
            guard operationID == id, !Task.isCancelled else { return true }
            applyCompletion(completion, context: presentationContext)
            statuses[row.id] = .updated
            selectedSkillIDs.remove(row.id)
            return true
        } catch {
            let didMutate = error is SyncedStateMutationError
            if didMutate { echoRegistrar([row.slug]) }
            guard operationID == id, !Task.isCancelled else { return didMutate }
            applyFailure(error, to: row)
            return didMutate
        }
    }

    private func applyFailure(_ error: Error, to row: UpdatesRow) {
        if error as? SkillUpdateFlowError == .localEditsRequireConfirmation {
            confirmedDriftSkillIDs.remove(row.id)
            if let index = rows.firstIndex(where: { $0.id == row.id }),
               !rows[index].driftedLocally {
                rows[index] = rows[index].markedDrifted()
            }
            statuses[row.id] = .confirmationRequired
        } else {
            statuses[row.id] = .failed(message: Self.readable(error),
                                       offersRecheck: Self.offersRecheck(error))
        }
    }

    private func notifyAfterApplyIfNeeded(_ didMutate: Bool) {
        if didMutate { notifier() }
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
        do {
            let completion = try await task.value
            guard operationID == id, !Task.isCancelled else { return }
            Self.applyRecheckCompletion(completion, context: presentationContext)
            if let checkError = completion.checkError {
                statuses[row.id] = .failed(message: checkError, offersRecheck: true)
            } else if let refreshed = completion.row,
               let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index] = refreshed
                statuses[row.id] = .idle
            } else {
                rows.removeAll { $0.id == row.id }
                selectedSkillIDs.remove(row.id)
                confirmedDriftSkillIDs.remove(row.id)
                statuses[row.id] = nil
            }
        } catch {
            guard operationID == id, !Task.isCancelled else { return }
            statuses[row.id] = .failed(message: Self.readable(error), offersRecheck: true)
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

    private func applyCompletion(_ completion: SkillUpdateCompletion,
                                 context: ModelContext) {
        guard let skill = try? context.fetch(FetchDescriptor<Skill>()).first(where: {
            $0.id == completion.skillID
        }) else { return }
        skill.name = completion.name
        skill.skillDescription = completion.skillDescription
        skill.installedOriginData = completion.installedOriginData
        skill.updatedAt = completion.updatedAt
        skill.resetUpdateCheckState()
    }

    static func applyRecheckCompletion(_ completion: SkillUpdateRecheckCompletion,
                                       context: ModelContext) {
        guard let skill = try? context.fetch(FetchDescriptor<Skill>()).first(where: {
            $0.id == completion.skillID
        }) else { return }
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
