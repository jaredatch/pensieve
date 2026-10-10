import Foundation
import SwiftData

/// Sheet state; native jobs own git, SwiftData and completion after dismissal.
@MainActor
@Observable
final class ConflictResolutionModel {
    enum Phase: Equatable {
        case loading
        case ready([ConflictGroup])
        case resolving
        case done
        case empty
        case error(String)
    }

    struct ConflictGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let items: [ConflictItem]
        var chosen: ConflictSide?
    }

    private(set) var phase: Phase = .loading
    private(set) var selectionError: String?

    private let steps: SyncStepModel
    @ObservationIgnored private var task: Task<Void, Never>?
    private var presentation = UUID()
    private var isPresented = true

    private(set) var isApplying = false
    var canCancel: Bool { !isApplying }

    private let engine: SyncEngineProtocol
    private let git: GitServiceProtocol
    private let credentials: CredentialStoreProtocol
    private let root: String
    private let headStamp: () -> String?
    private let now: () -> Date
    private let onResolutionStarted: () throws -> (SyncCycleResult) -> Void

    init(engine: SyncEngineProtocol,
         git: GitServiceProtocol,
         credentials: CredentialStoreProtocol,
         root: String,
         headStamp: (() -> String?)? = nil,
         now: @escaping () -> Date = Date.init,
         steps: SyncStepModel,
         onResolutionStarted: @escaping () throws -> (SyncCycleResult) -> Void = { { _ in } }) {
        self.steps = steps
        self.engine = engine
        self.git = git
        self.credentials = credentials
        self.root = root
        self.headStamp = headStamp ?? { GitHeadStamp().read(root: root) }
        self.now = now
        self.onResolutionStarted = onResolutionStarted
    }

    var canApply: Bool {
        guard case let .ready(groups) = phase, !groups.isEmpty else { return false }
        return groups.allSatisfy { $0.chosen != nil }
    }

    func load(container: ModelContainer) {
        guard task == nil else { return }
        isPresented = true
        presentation = UUID()
        phase = .loading
        selectionError = nil
        let step = steps.begin()
        let presentation = presentation
        task = Task {
            defer { steps.finish(step); task = nil }
            await inspect(container: container, presentation: presentation)
        }
    }

    /// Inspection writes to reproduce a conflict, so closing only retires presentation.
    func dismiss() {
        guard canCancel else { return }
        isPresented = false
        presentation = UUID()
    }

    private func inspect(container: ModelContainer, presentation: UUID) async {
        do {
            let onResolved = try onResolutionStarted()
            let job = makeJob(container: container)
            let result = try await BlockingWork.run { try job.inspect() }
            if case let .cleared(outcome) = result.inspection, case .synced = outcome {
                onResolved(cycleResult(from: outcome, previousHeadStamp: result.previousHeadStamp))
            }
            guard isPresented, self.presentation == presentation else { return }
            phase = result.groups.isEmpty ? .empty : .ready(result.groups)
        } catch {
            guard isPresented, self.presentation == presentation else { return }
            phase = .error((error as? LocalizedError)?.errorDescription ?? "Couldn't load conflicts.")
        }
    }

    func choose(_ groupID: String, _ side: ConflictSide) {
        guard case var .ready(groups) = phase,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if let unavailable = groups[index].items.first(where: {
            let receipt = side == .thisMachine ? $0.thisUnavailable : $0.otherUnavailable
            return receipt != nil && receipt?.canChoose != true
        }) {
            selectionError = SyncError.conflictSideUnavailable(path: unavailable.path).errorDescription
            return
        }
        selectionError = nil
        groups[index].chosen = side
        phase = .ready(groups)
    }

    func apply(container: ModelContainer) {
        guard task == nil, case let .ready(groups) = phase,
              !groups.isEmpty, groups.allSatisfy({ $0.chosen != nil }) else { return }
        phase = .resolving
        isApplying = true
        let step = steps.begin()
        task = Task {
            defer { isApplying = false; steps.finish(step); task = nil }
            await resolve(groups: groups, container: container)
        }
    }

    private func resolve(groups: [ConflictGroup], container: ModelContainer) async {
        do {
            let onResolved = try onResolutionStarted()
            let job = makeJob(container: container)
            let result = try await BlockingWork.run { try job.resolve(groups: groups) }
            switch result.outcome {
            case .synced:
                onResolved(cycleResult(from: result.outcome, previousHeadStamp: result.previousHeadStamp))
                phase = .done
            case .conflicted:
                await reinspect(container: container)
            case .noRemote, .branchless:
                phase = .empty
            }
        } catch SyncError.conflictsChanged {
            await reinspect(container: container)
        } catch SyncError.conflictSideUnavailable(let path) {
            selectionError = SyncError.conflictSideUnavailable(path: path).errorDescription
            phase = .ready(groups)
        } catch SyncError.conflictFolderMustMove(let path) {
            selectionError = SyncError.conflictFolderMustMove(path: path).errorDescription
            phase = .ready(groups)
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? "Couldn't resolve conflicts.")
        }
    }

    private func reinspect(container: ModelContainer) async {
        phase = .loading
        selectionError = nil
        await inspect(container: container, presentation: presentation)
    }

    private func makeJob(container: ModelContainer) -> ConflictResolutionJob {
        ConflictResolutionJob(container: container, engine: engine, git: git,
                              credentials: credentials, root: root, headStamp: headStamp)
    }

    private func cycleResult(from outcome: SyncOutcome, previousHeadStamp: String?) -> SyncCycleResult {
        guard case let .synced(pushed, warnings, ingestedHeadStamp) = outcome else {
            preconditionFailure("resolved conflict callback requires a synced outcome")
        }
        return .synced(
            pushed: pushed,
            warnings: warnings,
            completedAt: now(),
            headAdvanced: pushed || (ingestedHeadStamp != nil && ingestedHeadStamp != previousHeadStamp)
        )
    }

}
