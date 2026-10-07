import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SkillInstallViewModel {
    typealias State = SkillInstallState
    typealias ResultKind = SkillInstallReportKind
    typealias InstallReport = SkillInstallReport
    typealias PendingCollision = SkillInstallPendingCollision
    typealias URLParser = (String) -> Result<SkillInstallURL, SkillInstallURLParseError>

    var state: State = .idle
    var urlText = "" {
        didSet { parseURL() }
    }
    private(set) var parsedURL: SkillInstallURL?
    private(set) var urlRejectionReason: String?
    private(set) var source: SkillFetchResult?
    private(set) var selectedPaths: Set<String> = []
    var reports: [InstallReport] = []
    var pendingCollision: PendingCollision?
    var adoptTarget: SkillInstallAdoptTarget?
    var completedAdoptions: [SkillInstallAdoptionCompletion] = []
    var collisionRenameSlug = ""
    var collisionActionInFlight = false

    let service: SkillInstallServiceProtocol
    private let parse: URLParser
    var operationID: UUID?
    var operationTask: Task<Void, Never>?
    var backgroundCancel: (() -> Void)?
    var installQueue: [SkillCandidate] = []
    var installIndex = 0
    var mutatedOperationIDs: Set<UUID> = []
    var installContainer: ModelContainer?
    let notifier: SyncStateNotifying
    let echoRegistrar: SyncWriteEchoRegistering
    let bodyWriteRegistration: SyncBodyWriteRegistration
    init(
        service: SkillInstallServiceProtocol,
        parser: @escaping URLParser = SkillInstallURL.parseResult,
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
        echoRegistrar: @escaping SyncWriteEchoRegistering = SyncWriteEchoRegistrar.suppressed,
        bodyWriteRegistration: SyncBodyWriteRegistration = .suppressed
    ) {
        self.service = service
        self.parse = parser
        self.notifier = notifier
        self.echoRegistrar = echoRegistrar
        self.bodyWriteRegistration = bodyWriteRegistration
    }
    var candidates: [SkillCandidate] { source?.candidates ?? [] }
    var selectedCount: Int { selectedPaths.count }
    var canFetch: Bool {
        parsedURL != nil && state != .fetching && state != .installing
    }
    var canInstall: Bool {
        state == .picking && selectedCount > 0
    }
    func isSelected(_ candidate: SkillCandidate) -> Bool {
        selectedPaths.contains(candidate.path)
    }
    func toggleSelection(_ candidate: SkillCandidate) {
        guard state == .picking, candidate.isInstallable else { return }
        if selectedPaths.contains(candidate.path) {
            selectedPaths.remove(candidate.path)
        } else {
            selectedPaths.insert(candidate.path)
        }
    }
    func selectAll() {
        guard state == .picking else { return }
        selectedPaths = Set(candidates.filter(\.isInstallable).map(\.path))
    }
    func selectNone() {
        guard state == .picking else { return }
        selectedPaths.removeAll()
    }
    func reset() {
        abandonOperation()
        state = .idle
        urlText = ""
        parsedURL = nil
        urlRejectionReason = nil
        source = nil
        selectedPaths = []
        reports = []
        adoptTarget = nil
        completedAdoptions = []
        clearInstallState()
    }
    func cancel() {
        abandonOperation()
        state = .idle
        clearInstallState()
    }

    func fetch() {
        guard let request = beginFetch() else { return }
        operationTask = Task { await performFetch(request.url, operationID: request.id) }
    }

    func fetchAndReport() async {
        guard let request = beginFetch() else { return }
        await performFetch(request.url, operationID: request.id)
    }

    func retry() {
        fetch()
    }

    func installSelected(context: ModelContext) {
        guard let request = beginInstall(context: context) else { return }
        operationTask = Task {
            await runInstallQueue(operationID: request.id, container: request.container)
        }
    }

    func installSelectedAndReport(context: ModelContext) async {
        guard let request = beginInstall(context: context) else { return }
        await runInstallQueue(operationID: request.id, container: request.container)
    }

    func adoptCollision() {
        guard let request = beginCollisionAction() else { return }
        operationTask = Task {
            await performAdopt(request.collision, operationID: request.id, container: request.container)
        }
    }

    func adoptCollisionAndReport() async {
        guard let request = beginCollisionAction() else { return }
        await performAdopt(request.collision, operationID: request.id, container: request.container)
    }

    func renameCollision() {
        guard renameValidationReason == nil,
              let request = beginCollisionAction() else { return }
        let slug = collisionRenameSlug
        operationTask = Task {
            await performRename(request.collision, slug: slug,
                                operationID: request.id, container: request.container)
        }
    }

    func renameCollisionAndReport() async {
        guard renameValidationReason == nil,
              let request = beginCollisionAction() else { return }
        await performRename(request.collision, slug: collisionRenameSlug,
                            operationID: request.id, container: request.container)
    }

    func skipCollision() {
        guard state == .installing, let collision = pendingCollision,
              let id = operationID, let container = installContainer else { return }
        pendingCollision = nil
        reports.append(InstallReport(candidate: collision.candidate, result: .skipped))
        installIndex += 1
        operationTask = Task { await runInstallQueue(operationID: id, container: container) }
    }

    func skipCollisionAndReport() async {
        guard state == .installing, let collision = pendingCollision,
              let id = operationID, let container = installContainer else { return }
        pendingCollision = nil
        reports.append(InstallReport(candidate: collision.candidate, result: .skipped))
        installIndex += 1
        await runInstallQueue(operationID: id, container: container)
    }
}

extension SkillInstallViewModel {
    private func parseURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parsedURL = nil
            urlRejectionReason = nil
            return
        }
        switch parse(urlText) {
        case let .success(url):
            parsedURL = url
            urlRejectionReason = nil
        case let .failure(error):
            parsedURL = nil
            urlRejectionReason = error.localizedDescription
        }
    }

    private func beginFetch() -> (id: UUID, url: SkillInstallURL)? {
        guard canFetch, let parsedURL else { return nil }
        abandonOperation()
        let id = UUID()
        operationID = id
        state = .fetching
        source = nil
        selectedPaths = []
        reports = []
        clearInstallState(keepingOperation: true)
        return (id, parsedURL)
    }

    private func performFetch(_ url: SkillInstallURL, operationID id: UUID) async {
        // Entry guard: a cancel() that lands before this outer-task body runs nils operationID,
        // and a detached task created below would NOT inherit that cancellation. From here to
        // backgroundCancel registration is synchronous on the MainActor, so no cancel can slip
        // between the guard and the detached task's own cancellation hook.
        guard operationID == id, !Task.isCancelled else { return }
        let service = service
        let task = BlockingWork.task(priority: .userInitiated) {
            try Self.performUnlessCancelled { () throws -> SkillFetchResult in
                if let path = url.path {
                    return try service.fetch(repo: url.repo, ref: url.ref, path: path, credential: nil)
                }
                return try service.fetch(repo: url.repo, ref: url.ref, credential: nil)
            }
        }
        backgroundCancel = { task.cancel() }
        do {
            let fetched = try await task.value
            guard operationID == id, !Task.isCancelled else { return }
            if adoptTarget != nil, fetched.candidates.count != 1 {
                let count = fetched.candidates.count
                state = .failed(count == 0
                    ? "This repository did not resolve to a skill. Paste a link that identifies exactly one skill."
                    : "This repository contains \(count) skills. Paste a link that identifies exactly one skill.")
                finishBackgroundOperation(id: id)
                return
            }
            source = fetched
            selectedPaths = Set(fetched.candidates.filter(\.isInstallable).map(\.path))
            state = .picking
            finishBackgroundOperation(id: id)
        } catch {
            guard operationID == id, !Task.isCancelled else { return }
            state = .failed(readableFetchError(error, form: url.form))
            finishBackgroundOperation(id: id)
        }
    }

    private func beginInstall(context: ModelContext) -> (id: UUID, container: ModelContainer)? {
        guard canInstall, let source else { return nil }
        let chosen = source.candidates.filter { selectedPaths.contains($0.path) && $0.isInstallable }
        guard !chosen.isEmpty else { return nil }
        abandonOperation()
        let id = UUID()
        operationID = id
        state = .installing
        reports = []
        pendingCollision = nil
        collisionActionInFlight = false
        installQueue = chosen
        installIndex = 0
        installContainer = context.container
        return (id, context.container)
    }

    func runInstallQueue(operationID id: UUID, container: ModelContainer) async {
        guard operationID == id, let source else { return }
        while installIndex < installQueue.count {
            let candidate = installQueue[installIndex]
            let service = service
            let bodyWriteRegistration = bodyWriteRegistration
            let task = BlockingWork.task(priority: .userInitiated) {
                try Self.performUnlessCancelled { () throws -> SkillInstallResult in
                    let context = ModelContext(container)
                    return try service.install(
                        candidate: candidate, from: source, credential: nil,
                        bodyWriteRegistration: bodyWriteRegistration, context: context
                    )
                }
            }
            backgroundCancel = { task.cancel() }
            do {
                let result = try await task.value
                switch result {
                case let .installed(slug):
                    recordCanonicalWrite(operationID: id, slug: slug)
                    guard operationID == id, !Task.isCancelled else {
                        emitPendingMutationIfNeeded(operationID: id)
                        return
                    }
                    reports.append(InstallReport(candidate: candidate, result: .installed(slug: slug)))
                    installIndex += 1
                case let .collision(existing):
                    pendingCollision = PendingCollision(candidate: candidate, existing: existing)
                    collisionRenameSlug = candidate.slug + "-2"
                    finishBackgroundOperation(id: id, keepingOperationID: true)
                    return
                }
            } catch {
                if error is SyncedStateMutationError {
                    recordCanonicalWrite(operationID: id, slug: candidate.slug)
                }
                guard operationID == id, !Task.isCancelled else {
                    emitPendingMutationIfNeeded(operationID: id)
                    return
                }
                reports.append(InstallReport(candidate: candidate, result: .failed(readable(error))))
                installIndex += 1
            }
        }
        guard operationID == id else { return }
        state = .done
        clearInstallState(keepingOperation: true)
        finishBackgroundOperation(id: id)
    }

}
