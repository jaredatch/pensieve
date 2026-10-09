import Foundation
import SwiftData

extension SkillInstallViewModel {
    func beginCollisionAction() -> SkillInstallCollisionActionRequest? {
        guard state == .installing, !collisionActionInFlight,
              let id = operationID, let collision = pendingCollision,
              let container = installContainer else { return nil }
        collisionActionInFlight = true
        return SkillInstallCollisionActionRequest(id: id, collision: collision, container: container)
    }

    func performAdopt(_ collision: PendingCollision, operationID id: UUID, container: ModelContainer) async {
        guard operationID == id, !Task.isCancelled, let source else { return }
        let service = service
        let existingSlug = collision.existing.slug
        let task = BlockingWork.task(priority: .userInitiated) {
            try Self.performUnlessCancelled { () throws -> (SkillAdoptResult, SkillInstallAdoptionCompletion?) in
                let context = ModelContext(container)
                let result = try service.adopt(
                    existingSlug: existingSlug, candidate: collision.candidate,
                    from: source, credential: nil, context: context
                )
                let skill: Skill?
                do {
                    skill = try context.fetch(FetchDescriptor<Skill>())
                        .first(where: { $0.directoryName == existingSlug })
                } catch {
                    throw SyncedStateMutationError(underlyingError: error)
                }
                let completion = skill.flatMap { adopted in
                    adopted.installedOriginData.map { data in
                        SkillInstallAdoptionCompletion(
                            skillID: adopted.id, localDrift: result == .localDrift,
                            installedOriginData: data)
                    }
                }
                return (result, completion)
            }
        }
        backgroundCancel = { task.cancel() }
        do {
            let (result, completion) = try await task.value
            recordCanonicalWrite(operationID: id)
            guard operationID == id, !Task.isCancelled else {
                emitPendingMutationIfNeeded(operationID: id)
                return
            }
            reports.append(InstallReport(candidate: collision.candidate,
                result: .adopted(localDrift: result == .localDrift)))
            if let completion { completedAdoptions.append(completion) }
        } catch {
            if error is SyncedStateMutationError { recordCanonicalWrite(operationID: id) }
            guard operationID == id, !Task.isCancelled else {
                emitPendingMutationIfNeeded(operationID: id)
                return
            }
            reports.append(InstallReport(candidate: collision.candidate, result: .failed(readable(error))))
        }
        await finishCollisionAction(operationID: id, container: container)
    }

    func performRename(_ collision: PendingCollision, slug: String,
                       operationID id: UUID, container: ModelContainer) async {
        guard operationID == id, !Task.isCancelled, let source else { return }
        let service = service
        let bodyWriteRegistration = bodyWriteRegistration
        let task = BlockingWork.task(priority: .userInitiated) {
            try Self.performUnlessCancelled { () throws -> SkillInstallResult in
                let context = ModelContext(container)
                return try service.install(
                    candidate: collision.candidate,
                    renamedTo: slug,
                    from: source,
                    credential: nil,
                    bodyWriteRegistration: bodyWriteRegistration,
                    context: context
                )
            }
        }
        backgroundCancel = { task.cancel() }
        do {
            let result = try await task.value
            if case let .collision(existing) = result {
                guard operationID == id, !Task.isCancelled else { return }
                pendingCollision = PendingCollision(candidate: collision.candidate, existing: existing)
                collisionActionInFlight = false
                finishBackgroundOperation(id: id, keepingOperationID: true)
                return
            }
            recordCanonicalWrite(operationID: id, slug: slug)
            guard operationID == id, !Task.isCancelled else {
                emitPendingMutationIfNeeded(operationID: id)
                return
            }
            reports.append(InstallReport(candidate: collision.candidate, result: .installed(slug: slug)))
        } catch {
            if error is SyncedStateMutationError { recordCanonicalWrite(operationID: id, slug: slug) }
            guard operationID == id, !Task.isCancelled else {
                emitPendingMutationIfNeeded(operationID: id)
                return
            }
            reports.append(InstallReport(candidate: collision.candidate, result: .failed(readable(error))))
        }
        await finishCollisionAction(operationID: id, container: container)
    }

    private func finishCollisionAction(operationID id: UUID, container: ModelContainer) async {
        guard operationID == id else { return }
        pendingCollision = nil
        collisionActionInFlight = false
        installIndex += 1
        await runInstallQueue(operationID: id, container: container)
    }
}
