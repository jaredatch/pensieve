import Foundation
import SwiftData

/// One synchronous job creates and consumes its own context on the native worker.
struct ConflictResolutionJob {
    let container: ModelContainer
    let engine: SyncEngineProtocol
    let git: GitServiceProtocol
    let credentials: CredentialStoreProtocol
    let root: String
    let headStamp: () -> String?

    struct InspectionResult {
        let inspection: ConflictInspection
        let groups: [ConflictResolutionModel.ConflictGroup]
        let previousHeadStamp: String?
    }

    func inspect() throws -> InspectionResult {
        try GitCancellation.$isReadOnly.withValue(false) {
            let context = ModelContext(container)
            let previous = headStamp()
            let credential = try resolveCredential()
            let inspection = try engine.inspectConflicts(root: root, credential: credential, context: context)
            let groups: [ConflictResolutionModel.ConflictGroup]
            if case let .conflicts(set) = inspection {
                groups = try self.groups(from: set, context: context)
            } else { groups = [] }
            return InspectionResult(inspection: inspection, groups: groups, previousHeadStamp: previous)
        }
    }

    func resolve(groups: [ConflictResolutionModel.ConflictGroup]) throws
        -> (outcome: SyncOutcome, previousHeadStamp: String?) {
        try GitCancellation.$isReadOnly.withValue(false) {
            let context = ModelContext(container)
            let previous = headStamp()
            let picks = groups.reduce(into: [String: ResolutionPick]()) { partial, group in
                guard let side = group.chosen else { return }
                for item in group.items {
                    partial[item.path] = ResolutionPick(side: side, expectedThis: item.thisMachine,
                        expectedOther: item.otherMachine, expectedThisUnavailable: item.thisUnavailable,
                        expectedOtherUnavailable: item.otherUnavailable, expectedThisMode: item.thisMode,
                        expectedOtherMode: item.otherMode)
                }
            }
            let credential = try resolveCredential()
            return (try engine.resolveConflicts(root: root, picks: picks, credential: credential, context: context), previous)
        }
    }

    private func groups(from set: ConflictSet, context: ModelContext) throws -> [ConflictResolutionModel.ConflictGroup] {
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
            return ConflictResolutionModel.ConflictGroup(id: id,
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
