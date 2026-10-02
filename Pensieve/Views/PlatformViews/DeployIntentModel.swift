import Foundation
import Observation
import SwiftData

struct DeployIntentMachine: Identifiable, Equatable {
    let id: String
    let name: String
    let isLocal: Bool
    let isUnseen: Bool
}

struct DeployIntentDependencies {
    let identity: MachineIdentityProviding
    let stateService: MachineStateServicing
    let root: String
    let fetchIntents: (ModelContext) throws -> [MachineDeployIntent]
    let writeManifest: (ModelContext) throws -> Void
    let saveContext: (ModelContext) throws -> Void
    let notifier: SyncStateNotifying
    let reconcile: @MainActor (ModelContext) -> BatchResult
    let lockPath: String
    let lockProvider: (String) -> SyncLock?
    let remoteRetractions: RemoteRetractionStore

    init(
        identity: MachineIdentityProviding,
        stateService: MachineStateServicing,
        root: String,
        fetchIntents: @escaping (ModelContext) throws -> [MachineDeployIntent] = {
            try $0.fetch(FetchDescriptor<MachineDeployIntent>())
        },
        writeManifest: @escaping (ModelContext) throws -> Void,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
        notifier: @escaping SyncStateNotifying,
        reconcile: @escaping @MainActor (ModelContext) -> BatchResult = { _ in BatchResult() },
        lockPath: String,
        lockProvider: @escaping (String) -> SyncLock? = { SyncLock.tryAcquire(at: $0) },
        remoteRetractions: RemoteRetractionStore = RemoteRetractionStore()
    ) {
        self.identity = identity
        self.stateService = stateService
        self.root = root
        self.fetchIntents = fetchIntents
        self.writeManifest = writeManifest
        self.saveContext = saveContext
        self.notifier = notifier
        self.reconcile = reconcile
        self.lockPath = lockPath
        self.lockProvider = lockProvider
        self.remoteRetractions = remoteRetractions
    }

    static func live(
        identity: MachineIdentityProviding,
        stateService: MachineStateServicing,
        root: String,
        lockPath: String,
        notifier: @escaping SyncStateNotifying,
        reconcile: @escaping @MainActor (ModelContext) -> BatchResult,
        remoteRetractions: RemoteRetractionStore = RemoteRetractionStore()
    ) -> Self {
        let manifestService = ManifestService()
        return Self(
            identity: identity,
            stateService: stateService,
            root: root,
            writeManifest: { context in
                try manifestService.write(try manifestService.snapshot(from: context), toRoot: root)
            },
            notifier: notifier,
            reconcile: reconcile,
            lockPath: lockPath,
            remoteRetractions: remoteRetractions
        )
    }
}

enum DeployIntentApplyOutcome {
    case intentOnly
    case localDeploy(BatchResult)
}

enum DeployIntentModelError: LocalizedError {
    case invalidComponent(String)
    case remoteTargetIsThisMac
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case let .invalidComponent(value):
            "Invalid deploy intent component: \(value)"
        case .remoteTargetIsThisMac:
            "This Mac must use its local deployment controls."
        case .syncInProgress:
            "Sync is running. Try again when it finishes."
        }
    }
}

enum DeployIntentPersistenceError: LocalizedError {
    case manifestRestoreFailed(save: Error, restore: Error)

    var errorDescription: String? {
        switch self {
        case let .manifestRestoreFailed(save, restore):
            "Saving deployment intent failed (\(save.localizedDescription)), and the restore of its manifest failed "
                + "(\(restore.localizedDescription))."
        }
    }
}

@MainActor
@Observable
final class DeployIntentModel {
    let platformVM: PlatformViewModel
    let dependencies: DeployIntentDependencies

    private(set) var machines: [DeployIntentMachine] = []
    private(set) var availablePlatforms: [PlatformTarget] = []
    var error: String?

    init(platformVM: PlatformViewModel, dependencies: DeployIntentDependencies) {
        self.platformVM = platformVM
        self.dependencies = dependencies
    }

    func reload(context: ModelContext) {
        do {
            let localID = try dependencies.identity.identifier()
            let states = dependencies.stateService.readAll(fromRoot: dependencies.root)
            let stateByID = Dictionary(states.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
            let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>())
            let intentIDs = Set(intents.compactMap { $0.projectKey == nil ? $0.machineID : nil })
            let allIDs = Set(stateByID.keys).union(intentIDs).union([localID])
            machines = allIDs.map { machineID in
                let state = stateByID[machineID]
                return DeployIntentMachine(
                    id: machineID,
                    name: machineID == localID ? "This Mac" : state.map {
                        PublishedStringSanitizer.name($0.name, fallback: "Mac")
                    } ?? machineID,
                    isLocal: machineID == localID,
                    isUnseen: machineID != localID && state == nil
                )
            }.sorted {
                if $0.isLocal != $1.isLocal { return $0.isLocal }
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id < $1.id
            }
            let remoteRaws = states.flatMap(\.agents) + intents.filter { $0.projectKey == nil }.map(\.platformRaw)
            let remotePlatforms = remoteRaws.compactMap(PlatformTarget.init(rawValue:))
            let localPlatforms = platformVM.deployablePlatforms(forProject: false)
            let admitted = Set(localPlatforms + remotePlatforms)
            availablePlatforms = PlatformTarget.allCases.filter(admitted.contains)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func selectedMachineIDs(
        skills: [Skill],
        platforms: Set<PlatformTarget>,
        context: ModelContext
    ) throws -> Set<String> {
        let slugs = Set(skills.map(\.directoryName))
        let platformRaws = Set(platforms.map(\.rawValue))
        do {
            let rows = try dependencies.fetchIntents(context)
            return Set(rows.compactMap { row in
                row.projectKey == nil && slugs.contains(row.skillSlug) && platformRaws.contains(row.platformRaw)
                    ? row.machineID : nil
            })
        } catch {
            self.error = "Deployment selection could not be read: \(error.localizedDescription)"
            throw error
        }
    }
}
