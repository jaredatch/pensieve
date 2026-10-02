import Foundation
import SwiftData

extension SkillInstallViewModel {
    func prepareAdoption(of skill: Skill) {
        reset()
        adoptTarget = SkillInstallAdoptTarget(
            skillID: skill.id,
            slug: skill.directoryName,
            name: skill.name
        )
    }

    func confirm(context: ModelContext) {
        if adoptTarget != nil {
            adoptTargetedSkill(context: context)
        } else {
            installSelected(context: context)
        }
    }

    func confirmAndReport(context: ModelContext) async {
        if adoptTarget != nil {
            await adoptTargetedSkillAndReport(context: context)
        } else {
            await installSelectedAndReport(context: context)
        }
    }

    private func adoptTargetedSkill(context: ModelContext) {
        guard let request = beginTargetedAdoption(context: context) else { return }
        operationTask = Task {
            await performTargetedAdoption(request, operationID: request.id)
        }
    }

    private func adoptTargetedSkillAndReport(context: ModelContext) async {
        guard let request = beginTargetedAdoption(context: context) else { return }
        await performTargetedAdoption(request, operationID: request.id)
    }

    private func beginTargetedAdoption(
        context: ModelContext
    ) -> SkillInstallTargetedAdoptionRequest? {
        guard state == .picking, let target = adoptTarget, let source,
              source.candidates.count == 1, let candidate = source.candidates.first,
              candidate.isInstallable, repositoryIdentity != nil else { return nil }
        abandonOperation()
        let id = UUID()
        operationID = id
        state = .installing
        reports = []
        completedAdoptions = []
        installContainer = context.container
        return SkillInstallTargetedAdoptionRequest(
            id: id,
            target: target,
            candidate: candidate,
            source: source,
            container: context.container
        )
    }

    private func performTargetedAdoption(
        _ request: SkillInstallTargetedAdoptionRequest,
        operationID id: UUID
    ) async {
        guard operationID == id, !Task.isCancelled else { return }
        let service = service
        let task = Task.detached(priority: .userInitiated) {
            try Self.performTargetedAdoptionRequest(request, service: service)
        }
        backgroundCancel = { task.cancel() }
        do {
            let result = try await task.value
            recordCanonicalWrite(operationID: id)
            guard operationID == id, !Task.isCancelled else {
                emitPendingMutationIfNeeded(operationID: id)
                return
            }
            let drifted = result.result == .localDrift
            reports = [InstallReport(
                candidate: request.candidate,
                result: .adopted(localDrift: drifted)
            )]
            completedAdoptions.append(SkillInstallAdoptionCompletion(
                skillID: request.target.skillID,
                localDrift: drifted,
                installedOriginData: result.installedOriginData
            ))
            state = .done
        } catch {
            if error is SyncedStateMutationError { recordCanonicalWrite(operationID: id) }
            guard operationID == id, !Task.isCancelled else {
                emitPendingMutationIfNeeded(operationID: id)
                return
            }
            state = .failed(readable(error))
        }
        clearInstallState(keepingOperation: true)
        finishBackgroundOperation(id: id)
    }

    nonisolated private static func performTargetedAdoptionRequest(
        _ request: SkillInstallTargetedAdoptionRequest,
        service: SkillInstallServiceProtocol
    ) throws -> SkillInstallTargetedAdoptionResult {
        try performUnlessCancelled {
            let context = ModelContext(request.container)
            let result = try service.adopt(
                existingSlug: request.target.slug,
                candidate: request.candidate,
                from: request.source,
                credential: nil,
                context: context
            )
            let skill: Skill?
            do {
                skill = try context.fetch(FetchDescriptor<Skill>()).first(where: {
                    $0.id == request.target.skillID
                })
            } catch {
                throw SyncedStateMutationError(underlyingError: error)
            }
            guard let installedOriginData = skill?.installedOriginData else {
                throw SyncedStateMutationError(
                    underlyingError: SkillInstallError.existingSkillNotFound(request.target.slug)
                )
            }
            return SkillInstallTargetedAdoptionResult(
                result: result,
                installedOriginData: installedOriginData
            )
        }
    }
}
