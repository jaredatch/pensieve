import Foundation
import SwiftData

/// Conflict-resolution state for the PLAN-09 sheet.
///
/// `@MainActor`: `load` and `apply` schedule synchronous git work through `Task`, mirroring
/// `SyncModel`. That Task inherits the main actor, so the git work can still block the UI on slow
/// storage/network; moving it off-main is a tracked refinement. Tests drive the awaitable seams.
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
         onResolutionStarted: @escaping () throws -> (SyncCycleResult) -> Void = { { _ in } }) {
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

    /// Fire-and-forget entry for the sheet. Tests call `loadAndReport` directly.
    func load(context: ModelContext) {
        phase = .loading
        Task { await loadAndReport(context: context) }
    }

    /// Awaitable seam (tests await this; the sheet goes through `load`).
    func loadAndReport(context: ModelContext) async {
        phase = .loading
        selectionError = nil
        let previousHeadStamp = headStamp()
        do {
            let onResolved = try onResolutionStarted()
            let credential = try resolveCredential()
            let inspection = try engine.inspectConflicts(root: root, credential: credential,
                                                         context: context)
            switch inspection {
            case let .cleared(outcome):
                onResolved(cycleResult(from: outcome, previousHeadStamp: previousHeadStamp))
                phase = .empty
            case let .conflicts(set):
                let groups = try groups(from: set, context: context)
                phase = groups.isEmpty ? .empty : .ready(groups)
            }
        } catch let error as LocalizedError {
            phase = .error(error.errorDescription ?? "Couldn't load conflicts.")
        } catch {
            phase = .error("Couldn't load conflicts.")
        }
    }

    func choose(_ groupID: String, _ side: ConflictSide) {
        guard case var .ready(groups) = phase,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if let unavailable = groups[index].items.first(where: {
            (side == .thisMachine ? $0.thisUnavailable : $0.otherUnavailable) != nil
        }) {
            selectionError = SyncError.conflictSideUnavailable(path: unavailable.path).errorDescription
            return
        }
        selectionError = nil
        groups[index].chosen = side
        phase = .ready(groups)
    }

    /// Fire-and-forget entry for the sheet. Tests call `applyAndReport` directly.
    func apply(context: ModelContext) {
        guard case let .ready(groups) = phase,
              groups.allSatisfy({ $0.chosen != nil }) else { return }
        phase = .resolving
        Task { await apply(groups: groups, context: context) }
    }

    /// Awaitable seam (tests await this; the sheet goes through `apply`).
    func applyAndReport(context: ModelContext) async {
        guard case let .ready(groups) = phase,
              groups.allSatisfy({ $0.chosen != nil }) else { return }
        await apply(groups: groups, context: context)
    }

    private func apply(groups: [ConflictGroup], context: ModelContext) async {
        phase = .resolving
        let picks = groups.reduce(into: [String: ResolutionPick]()) { partial, group in
            guard let side = group.chosen else { return }
            for item in group.items {
                partial[item.path] = ResolutionPick(side: side, expectedThis: item.thisMachine,
                                                    expectedOther: item.otherMachine,
                                                    expectedThisUnavailable: item.thisUnavailable,
                                                    expectedOtherUnavailable: item.otherUnavailable)
            }
        }
        let previousHeadStamp = headStamp()
        do {
            let onResolved = try onResolutionStarted()
            let credential = try resolveCredential()
            let outcome = try engine.resolveConflicts(root: root, picks: picks,
                                                      credential: credential, context: context)
            switch outcome {
            case .synced:
                onResolved(cycleResult(from: outcome, previousHeadStamp: previousHeadStamp))
                phase = .done
            case .conflicted:
                await loadAndReport(context: context)
            case .noRemote, .branchless:
                phase = .empty
            }
        } catch SyncError.conflictsChanged {
            await loadAndReport(context: context)
        } catch SyncError.conflictSideUnavailable(let path) {
            selectionError = SyncError.conflictSideUnavailable(path: path).errorDescription
            phase = .ready(groups)
        } catch let error as LocalizedError {
            phase = .error(error.errorDescription ?? "Couldn't resolve conflicts.")
        } catch {
            phase = .error("Couldn't resolve conflicts.")
        }
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

    private func groups(from set: ConflictSet, context: ModelContext) throws -> [ConflictGroup] {
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let namesBySlug = Dictionary(skills.map { ($0.directoryName, $0.name) }, uniquingKeysWith: { min($0, $1) })
        var order: [String] = []
        var itemsByID: [String: [ConflictItem]] = [:]
        for item in set.items {
            let id = entityID(for: item)
            if itemsByID[id] == nil { order.append(id) }
            itemsByID[id, default: []].append(item)
        }
        return order.compactMap { id in
            guard let items = itemsByID[id] else { return nil }
            return ConflictGroup(id: id,
                                 title: title(for: id, items: items, namesBySlug: namesBySlug),
                                 subtitle: subtitle(for: items),
                                 items: items,
                                 chosen: nil)
        }
    }

    private func entityID(for item: ConflictItem) -> String {
        let path = SyncEngine.conflictPath(for: item)
        switch path.kind {
        case .body:
            return path.skillSlug.map { "skill:" + $0 } ?? "body-path:" + item.path
        case .overlay:
            return path.skillSlug.map { "skill:" + $0 } ?? "overlay-path:" + item.path
        case .category:
            return path.slug.map { "category:" + $0 } ?? "category-path:" + item.path
        case .project:
            return "project:registry"
        }
    }

    private func title(for id: String, items: [ConflictItem], namesBySlug: [String: String]) -> String {
        guard let item = items.first else { return id }
        let path = SyncEngine.conflictPath(for: item)
        if path.kind == .project { return "Project registry" }
        if path.kind == .category { return "Category: " + (path.slug ?? item.path) }
        guard let slug = path.skillSlug else { return item.path }
        return namesBySlug[slug] ?? slug
    }

    private func subtitle(for items: [ConflictItem]) -> String {
        let kinds = Set(items.map(\.kind))
        if kinds.contains(.body) && kinds.contains(.overlay) { return "Body and settings differ" }
        if kinds.contains(.body) { return "Body differs" }
        return "Settings differ"
    }

    private func resolveCredential() throws -> GitCredential? {
        try git.probeUsability().requireUsable()
        guard let remote = try git.remoteURL(at: root),
              let spec = SyncSetupModel.parseRemote(remote) else { return nil }
        switch spec.transport {
        case .ssh:
            return .sshAgent
        case .https:
            return credentials.credential(forHost: spec.host)
        }
    }
}
